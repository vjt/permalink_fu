begin
  require 'iconv'
rescue Object
  puts "no iconv, you might want to look into it."
end

require 'digest/sha1'
module PermalinkFu
  class << self
    attr_accessor :translation_to
    attr_accessor :translation_from

    # This method does the actual permalink escaping.
    def escape(string)
      result = ((translation_to && translation_from) ? Iconv.iconv(translation_to, translation_from, string) : string).to_s
      result.gsub!(/[^\x00-\x7F]+/, '') # Remove anything non-ASCII entirely (e.g. diacritics).
      result.gsub!(/[^\w_ \-]+/i,   '') # Remove unwanted chars.
      result.gsub!(/[ \-]+/i,      '-') # No more than one of the separator in a row.
      result.gsub!(/^\-|\-$/i,      '') # Remove leading/trailing separator.
      result.downcase!
      result.size.zero? ? random_permalink(string) : result
    rescue
      random_permalink(string)
    end
    
    def random_permalink(seed = nil)
      Digest::SHA1.hexdigest("#{seed}#{Time.now.to_s.split(//).sort_by {rand}}")
    end
  end

  # This is the plugin method available on all ActiveRecord models.
  module PluginMethods
    # Specifies the given field(s) as a permalink, meaning it is passed through PermalinkFu.escape and set to the permalink_field.  This
    # is done
    #
    #   class Foo < ActiveRecord::Base
    #     # stores permalink form of #title to the #permalink attribute
    #     has_permalink :title
    #   
    #     # stores a permalink form of "#{category}-#{title}" to the #permalink attribute
    #   
    #     has_permalink [:category, :title]
    #   
    #     # stores permalink form of #title to the #category_permalink attribute
    #     has_permalink [:category, :title], :category_permalink
    #
    #     # add a scope
    #     has_permalink :title, :scope => :blog_id
    #
    #     # add a scope and specify the permalink field name
    #     has_permalink :title, :slug, :scope => :blog_id
    #
    #     # do not bother checking for a unique scope
    #     has_permalink :title, :unique => false
    #   end
    #
    def has_permalink(attr_names = [], permalink_field = nil, options = {})
      if permalink_field.is_a?(Hash)
        options = permalink_field
        permalink_field = nil
      end
      ClassMethods.setup_permalink_fu_on self do
        self.permalink_attributes = Array(attr_names)
        self.permalink_field      = (permalink_field || 'permalink').to_s
        self.permalink_options    = {:unique => true}.update(options)
        self.redirect_model       = options.delete(:redirect_model) || Redirect
      end
    end
  end

  # Contains class methods for ActiveRecord models that have permalinks
  module ClassMethods
    def self.setup_permalink_fu_on(base)
      base.extend self
      class << base
        attr_accessor :permalink_options
        attr_accessor :permalink_attributes
        attr_accessor :permalink_field
        attr_accessor :redirect_model
      end
      base.send :include, InstanceMethods

      yield

      if base.permalink_options[:unique]
        base.before_validation :create_unique_permalink
      else
        base.before_validation :create_common_permalink
      end

      class << base
        alias_method :define_attribute_methods_without_permalinks, :define_attribute_methods
        alias_method :define_attribute_methods, :define_attribute_methods_with_permalinks
      end
    end

    def define_attribute_methods_with_permalinks
      if value = define_attribute_methods_without_permalinks
        evaluate_attribute_method permalink_field, "def #{self.permalink_field}=(new_value);write_attribute(:#{self.permalink_field}, new_value ? PermalinkFu.escape(new_value) : nil);end", "#{self.permalink_field}="
      end
      value
    end

    def find_by_id_or_permalink(id)
      self.find(:first, :conditions => ["id = ? OR #{self.permalink_field} = ?", id, id]) or raise ActiveRecord::RecordNotFound
    end
  end

  # This contains instance methods for ActiveRecord models that have permalinks.
  module InstanceMethods
    def to_param
      read_attribute(self.class.permalink_field) || id.to_s
    end

  protected
    def create_common_permalink
      return unless should_create_permalink?
      send("#{self.class.permalink_field}=", create_permalink_for(self.class.permalink_attributes))

      limit   = self.class.columns_hash[self.class.permalink_field].limit
      base    = send("#{self.class.permalink_field}=", read_attribute(self.class.permalink_field)[0..limit - 1])
      [limit, base]
    end

    def create_unique_permalink
      limit, base = create_common_permalink
      return if limit.nil?
      counter = 1
      # oh how i wish i could use a hash for conditions
      conditions = ["#{self.class.permalink_field} = ?", base]
      unless new_record?
        conditions.first << " and id != ?"
        conditions       << id
      end
      if self.class.permalink_options[:scope]
        [self.class.permalink_options[:scope]].flatten.each do |scope|
          value = send(scope)
          if value
            conditions.first << " and #{scope} = ?"
            conditions       << send(scope)
          else
            conditions.first << " and #{scope} IS NULL"
          end
        end
      end
      while self.class.exists?(conditions)
        suffix = "-#{counter += 1}"
        conditions[1] = "#{base[0..limit-suffix.size-1]}#{suffix}"
        send("#{self.class.permalink_field}=", conditions[1])
      end
    end

    def create_permalink_for(attr_names)
      attr_names.collect { |attr_name| send(attr_name).to_s } * " "
    end

  private
    def should_create_permalink?
      return false unless create_redirect_if_permalink_fields_changed

      if self.class.permalink_options[:if]
        evaluate_method(self.class.permalink_options[:if])
      elsif self.class.permalink_options[:unless]
        !evaluate_method(self.class.permalink_options[:unless])
      else
        true
      end
    end

    # Create a new Redirect instance if the fields have been changed
    def create_redirect_if_permalink_fields_changed
      former = send(self.class.permalink_field)
      current = PermalinkFu.escape(create_permalink_for(self.class.permalink_attributes))
      attributes = {:model => self.class.name, :former_permalink => former, :current_permalink => current}

      if !former.nil? && former != current
        # If the model attributes are being rolled back to some older value, delete the old redirect
        self.class.redirect_model.delete_all :model => self.class.name, :former_permalink => current
        self.class.redirect_model.update_all ['current_permalink = ?', current], :current_permalink => former

        self.class.redirect_model.create(attributes)
      end

      return former != current
    end

    def evaluate_method(method)
      case method
      when Symbol
        send(method)
      when String
        eval(method, instance_eval { binding })
      when Proc, Method
        method.call(self)
      end
    end
  end

  module Controller
    module ClassMethods
      def handles_permalink_redirects(options = {})
        class << self
          attr_accessor :redirect_model, :data_model
        end

        self.redirect_model = options.delete(:using) || Redirect
        self.data_model     = options.delete(:on)    || self.name.sub(/Controller$/, '').singularize.constantize

        before_filter :check_for_former_permalink, {:only => :show}.merge(options)
    
        include InstanceMethods
      end
    end

    module InstanceMethods
      def check_for_former_permalink
        redirect = self.class.redirect_model.find(:first,
          :conditions => {:model => self.class.data_model.name, :former_permalink => params[:id]})

        return unless redirect
        redirect_to request.path.sub(/[\w-]+$/i, redirect.current_permalink)
      end
    end
  end
end

if Object.const_defined?(:Iconv)
  PermalinkFu.translation_to   = 'ascii//translit//IGNORE'
  PermalinkFu.translation_from = 'utf-8'
end
