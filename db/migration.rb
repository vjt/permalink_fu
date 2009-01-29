class CreateRedirectsTableForPermalinks < ActiveRecord::Migration
  def self.up
    create_table :redirects do |t|
      t.string :model
      t.string :former_permalink
      t.string :current_permalink

      t.timestamps
    end
  end

  def self.down
    drop_table :redirects
  end
end
