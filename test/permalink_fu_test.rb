require 'test/unit'
require File.join(File.dirname(__FILE__), '../lib/permalink_fu')

begin
  require 'rubygems'
  require 'ruby-debug'
  Debugger.start
rescue LoadError
  puts "no ruby debugger"
end


class FauxColumn < Struct.new(:limit)
end

class BaseModel
  def self.columns_hash
    @columns_hash ||= {'permalink' => FauxColumn.new(100)}
  end

  def self.inherited(base)
    subclasses << base
  end

  extend PermalinkFu::PluginMethods
  attr_accessor :id
  attr_accessor :title
  attr_accessor :extra
  attr_reader   :permalink
  attr_accessor :foo

  class << self
    attr_accessor :validation, :subclasses
  end
  self.subclasses = []

  def self.generated_methods
    @generated_methods ||= []
  end
  
  def self.primary_key
    :id
  end
  
  def self.logger
    nil
  end

  def self.has_many *args
    nil
  end

  def self.define_attribute_methods
    return unless generated_methods.empty?
    true
  end

  # ripped from AR
  def self.evaluate_attribute_method(attr_name, method_definition, method_name=attr_name)

    unless method_name.to_s == primary_key.to_s
      generated_methods << method_name
    end

    begin
      class_eval(method_definition, __FILE__, __LINE__)
    rescue SyntaxError => err
      generated_methods.delete(attr_name)
      if logger
        logger.warn "Exception occurred during reader method compilation."
        logger.warn "Maybe #{attr_name} is not a valid Ruby identifier?"
        logger.warn "#{err.message}"
      end
    end
  end

  def self.exists?(*args)
    false
  end

  def self.before_validation(method)
    self.validation = method
  end

  def validate
    send self.class.validation if self.class.validation
    permalink
  end
  
  def new_record?
    @id.nil?
  end
  
  def write_attribute(key, value)
    instance_variable_set "@#{key}", value
  end
  
  def read_attribute(key)
    instance_variable_get "@#{key}"
  end
end

class Redirect < BaseModel
  attr_accessor :model
  attr_accessor :former_permalink, :current_permalink
  attr_accessor :created_at, :updated_at

  define_attribute_methods

  @records = []

  def initialize(attributes)
    attributes.each { |k,v| self.send("#{k}=", v) }
  end

  def destroy
    self.class.destroy(self)
  end

  def self.table_name
    'redirects'
  end

  def self.find(what, options = {})
    finder = what == :all ? :select : :find

    if options[:order]
      @records.sort_by { |record| record.send(options[:order]) }
    else
      @records
    end.send(finder) { |record| options[:conditions] ?
      options[:conditions].all? { |key,value| value == record.send(key) } : true }
  end

  def self.exists?(attributes)
    !find(:first, :conditions => attributes)
  end

  def self.create(attributes)
    @records << new(attributes.merge(:created_at => Time.now, :updated_at => Time.now))
  end

  def self.count
    @records.size
  end

  def self.clear
    @records.clear
  end

  def self.destroy(record)
    @records.reject! { |r| r.model == record.model &&
      r.former_permalink == record.former_permalink &&
      r.current_permalink == record.current_permalink }
  end

  def self.delete_all(conditions)
    find(:all, :conditions => conditions).each { |r| r.destroy }
  end

  def self.destroy_all(conditions)
    delete_all(conditions)
  end

  def self.update_all(updates, conditions = nil)
    find(:all, :conditions => conditions).each do |r|
      updates.first.scan(/\w+\s*=/).map do |s|
        s.sub(/\s+/, '').intern 
      end.each_with_index { |attr, i| r.send(attr, updates[i+1]) }
    end
  end
end

class MockModel < BaseModel
  def self.exists?(conditions)
    if conditions[1] == 'foo'   || conditions[1] == 'bar' || 
      (conditions[1] == 'bar-2' && conditions[2] != 2)
      true
    else
      false
    end
  end

  has_permalink :title
end

class CommonMockModel < BaseModel
  def self.exists?(conditions)
    false # oh noes
  end

  has_permalink :title, :unique => false
end

class ScopedModel < BaseModel
  def self.exists?(conditions)
    if conditions[1] == 'foo' && conditions[2] != 5
      true
    else
      false
    end
  end

  has_permalink :title, :scope => :foo
end

class ScopedModelForNilScope < BaseModel
  def self.exists?(conditions)
    (conditions[0] == 'permalink = ? and foo IS NULL') ? (conditions[1] == 'ack') : false
  end

  has_permalink :title, :scope => :foo
end

class OverrideModel < BaseModel
  has_permalink :title
  
  def permalink
    'not the permalink'
  end
end

class IfProcConditionModel < BaseModel
  has_permalink :title, :if => Proc.new { |obj| false }
end

class IfMethodConditionModel < BaseModel
  has_permalink :title, :if => :false_method
  
  def false_method; false; end
end

class IfStringConditionModel < BaseModel
  has_permalink :title, :if => 'false'
end

class UnlessProcConditionModel < BaseModel
  has_permalink :title, :unless => Proc.new { |obj| false }
end

class UnlessMethodConditionModel < BaseModel
  has_permalink :title, :unless => :false_method
  
  def false_method; false; end
end

class UnlessStringConditionModel < BaseModel
  has_permalink :title, :unless => 'false'
end

class MockModelExtra < BaseModel
  has_permalink [:title, :extra]
end

# trying to be like ActiveRecord, define the attribute methods manually
BaseModel.subclasses.each { |c| c.send :define_attribute_methods }

class PermalinkFuTest < Test::Unit::TestCase
  @@samples = {
    'This IS a Tripped out title!!.!1  (well/ not really)'.freeze => 'this-is-a-tripped-out-title1-well-not-really'.freeze,
    '////// meph1sto r0x ! \\\\\\'.freeze => 'meph1sto-r0x'.freeze,
    'āčēģīķļņū'.freeze => 'acegiklnu'.freeze,
    '中文測試 chinese text'.freeze => 'chinese-text'.freeze,
    'fööbär'.freeze => 'foobar'.freeze
  }

  @@extra = { 'some-)()()-ExtRa!/// .data==?>    to \/\/test'.freeze => 'some-extra-data-to-test'.freeze }

  def test_should_escape_permalinks
    @@samples.each do |from, to|
      assert_equal to, PermalinkFu.escape(from)
    end
  end
  
  def test_should_escape_activerecord_model
    @m = MockModel.new
    @@samples.each do |from, to|
      @m.title = from; @m.permalink = nil
      assert_equal to, @m.validate
    end
  end
  
  def test_should_create_redirect_if_attributes_change
    @m = MockModel.new
    Redirect.clear

    @m.title = 'antani'
    @m.validate
    assert_equal 0, Redirect.count

    @m.title = 'tapioca'
    @m.validate
    assert_equal 1, Redirect.count

    assert_not_nil Redirect.find(:first, :conditions => {:model => 'MockModel',
      :former_permalink => 'antani', :current_permalink => 'tapioca'})
  end

  def test_should_not_create_redirect_if_attributes_dont_change
    @m = MockModel.new
    Redirect.clear

    @m.title = 'antani'
    @m.validate

    @m.title = 'antani'
    @m.validate

    assert Redirect.count.zero?
  end

  def test_should_remove_redirect_if_attributes_are_rolled_back
    @m = MockModel.new
    Redirect.clear

    @m.title = 'antani' ; @m.validate
    @m.title = 'tapioca'; @m.validate
    @m.title = 'sblinda'; @m.validate
    @m.title = 'antani' ; @m.validate

    assert_equal 2, Redirect.count
    assert_not_nil Redirect.find(:first, :conditions => {:model => 'MockModel',
      :former_permalink => 'tapioca', :current_permalink => 'antani'})
    assert_not_nil Redirect.find(:first, :conditions => {:model => 'MockModel',
      :former_permalink => 'sblinda', :current_permalink => 'antani'})
  end

  def test_multiple_attribute_permalink
    @m = MockModelExtra.new
    @@samples.each do |from, to|
      @@extra.each do |from_extra, to_extra|
        @m.title = from; @m.extra = from_extra; @m.permalink = nil
        assert_equal "#{to}-#{to_extra}", @m.validate
      end
    end
  end
  
  def test_should_create_unique_permalink
    @m = MockModel.new
    @m.title = 'foo'
    @m.validate
    assert_equal 'foo-2', @m.permalink
    
    @m.title = 'bar'
    @m.validate
    assert_equal 'bar-3', @m.permalink
  end
  
  def test_should_common_permalink_if_unique_is_false
    @m = CommonMockModel.new
    @m.title = 'foo'
    @m.validate
    assert_equal 'foo', @m.permalink
  end
  
  def test_should_not_check_itself_for_unique_permalink
    @m = MockModel.new
    @m.id = 2
    @m.title = 'bar-2'
    @m.validate
    assert_equal 'bar-2', @m.permalink
  end
  
  def test_should_create_unique_scoped_permalink
    @m = ScopedModel.new
    @m.title = 'foo'
    @m.validate
    assert_equal 'foo-2', @m.permalink
  
    @m.foo = 5
    @m.title = 'foo'
    @m.validate
    assert_equal 'foo', @m.permalink
  end
  
  def test_should_limit_permalink
    @old = MockModel.columns_hash['permalink'].limit
    MockModel.columns_hash['permalink'].limit = 2
    @m   = MockModel.new
    @m.title = 'BOO'
    assert_equal 'bo', @m.validate
  ensure
    MockModel.columns_hash['permalink'].limit = @old
  end
  
  def test_should_limit_unique_permalink
    @old = MockModel.columns_hash['permalink'].limit
    MockModel.columns_hash['permalink'].limit = 3
    @m   = MockModel.new
    @m.title = 'foo'
    assert_equal 'f-2', @m.validate
  ensure
    MockModel.columns_hash['permalink'].limit = @old
  end
  
  def test_should_abide_by_if_proc_condition
    @m = IfProcConditionModel.new
    @m.title = 'dont make me a permalink'
    @m.validate
    assert_nil @m.permalink
  end
  
  def test_should_abide_by_if_method_condition
    @m = IfMethodConditionModel.new
    @m.title = 'dont make me a permalink'
    @m.validate
    assert_nil @m.permalink
  end
  
  def test_should_abide_by_if_string_condition
    @m = IfStringConditionModel.new
    @m.title = 'dont make me a permalink'
    @m.validate
    assert_nil @m.permalink
  end
  
  def test_should_abide_by_unless_proc_condition
    @m = UnlessProcConditionModel.new
    @m.title = 'make me a permalink'
    @m.validate
    assert_not_nil @m.permalink
  end
  
  def test_should_abide_by_unless_method_condition
    @m = UnlessMethodConditionModel.new
    @m.title = 'make me a permalink'
    @m.validate
    assert_not_nil @m.permalink
  end
  
  def test_should_abide_by_unless_string_condition
    @m = UnlessStringConditionModel.new
    @m.title = 'make me a permalink'
    @m.validate
    assert_not_nil @m.permalink
  end
  
  def test_should_allow_override_of_permalink_method
    @m = OverrideModel.new
    @m.write_attribute(:permalink, 'the permalink')
    assert_not_equal @m.permalink, @m.read_attribute(:permalink)
  end
  
  def test_should_create_permalink_from_attribute_not_attribute_accessor
    @m = OverrideModel.new
    @m.title = 'the permalink'
    @m.validate
    assert_equal 'the-permalink', @m.read_attribute(:permalink)
  end
  
  def test_should_update_permalink_if_field_changed
    @m = OverrideModel.new
    @m.title = 'the permalink'
    @m.validate
    assert_equal 'the-permalink', @m.read_attribute(:permalink)
  end
  
  def test_should_work_correctly_for_scoped_fields_with_nil_value
    s1 = ScopedModelForNilScope.new
    s1.title = 'ack'
    s1.foo = 3
    s1.validate
    assert_equal 'ack', s1.permalink
    
    s2 = ScopedModelForNilScope.new
    s2.title = 'ack'
    s2.foo = nil
    s2.validate
    assert_equal 'ack-2', s2.permalink
  end
end
