class AddSha256Index < ActiveRecord::Migration[7.0]
  def change
    add_index :jobs, :sha256
  end
end
