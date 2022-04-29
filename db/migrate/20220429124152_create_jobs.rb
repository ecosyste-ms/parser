class CreateJobs < ActiveRecord::Migration[7.0]
  def change
    enable_extension 'pgcrypto' unless extension_enabled?('pgcrypto')

    create_table :jobs, id: :uuid, default: 'gen_random_uuid()' do |t|
      t.string :sidekiq_id
      t.string :status
      t.string :url
      t.json :results, default: {}

      t.timestamps
    end
  end
end
