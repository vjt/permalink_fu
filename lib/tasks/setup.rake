namespace :permalink_fu do
  desc "Sets up the Redirect model for permalink_fu"
  task :setup => :environment do

    model_name = ENV['MODEL_NAME'].capitalize rescue 'Redirect'

    # Create the Redirect model
    model_file = "app/models/#{model_name.downcase}.rb"
    unless File.exists? model_file
      File.open(model_file, 'w+') do |f|
        f.write "class #{model_name} < ActiveRecord::Base\nend\n"
      end

      puts "Wrote #{model_name} model in #{model_file}"
    end

    # Create the database migration
    table_name = model_name.tableize
    migration_name = "create_#{table_name}_table_for_permalinks.rb"

    if Dir["db/migrate/*_#{migration_name}"].empty?
      File.open("db/migrate/#{Time.now.strftime '%Y%m%d%H%M%S'}_#{migration_name}", 'w+') do |f|

        migration = File.read('vendor/plugins/permalink_fu/db/migration.rb').
          gsub(/Redirects/, model_name.pluralize). 
          gsub(/redirects/, table_name)

        f.write(migration)
      end

      puts "Wrote #{model_name} migration in #{migration_name}."
      puts "Don't forget to run `rake db:migrate`."
    end

  end
end
