namespace :aws do

  namespace :rds do

    desc "Launch an RDS instance"
    task :launch, [:id, :key, :snapshot, :new_db, :region] do |cmd, args|
      credentials = Aws::Credentials.new(args[:id], args[:key])
      client = Aws::RDS::Client.new(region: args[:region], credentials: credentials)

      dump_instance = client.describe_db_instances.db_instances.
        select { |instance| instance.db_instance_identifier ==  args[:new_db]}.
        first

      if !dump_instance
        puts "Launching Database with identifier #{args[:new_db]}"
        latest_snapshot = client.describe_db_snapshots.db_snapshots.
          select { |snap| snap.db_instance_identifier == args[:snapshot] }.
          sort { |s1,s2| s1.snapshot_create_time <=> s2.snapshot_create_time }.
          last

        dump_instance = client.restore_db_instance_from_db_snapshot(
          db_instance_identifier: args[:new_db],
          db_snapshot_identifier: latest_snapshot.db_snapshot_identifier
        )
      else
        puts "Instance #{args[:new_db]} already exists"
      end
    end

  end

end
