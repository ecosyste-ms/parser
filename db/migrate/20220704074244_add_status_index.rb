class AddStatusIndex < ActiveRecord::Migration[7.0]
  def change
    add_index :jobs, :status
  end
end
