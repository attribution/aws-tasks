require 'aws-sdk'

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

    desc "Destroy an RDS instance"
    task :destroy, [:id, :key, :region, :identifier] do |cmd, args|
      credentials = Aws::Credentials.new(args[:id], args[:key])
      client = Aws::RDS::Client.new(region: args[:region], credentials: credentials)
      client.delete_db_instance(db_instance_identifier: args[:identifier], skip_final_snapshot: true)
    end

  end

  namespace :redshift do

    desc "Launch a Redshift instance"
    task :launch, [:id, :key, :snapshot, :new_db, :region, :security_group_id] do |cmd, args|
      credentials = Aws::Credentials.new(args[:id], args[:key])
      client = Aws::Redshift::Client.new(region: args[:region], credentials: credentials)

      dump_instance = client.describe_clusters.clusters.
        select { |instance| instance.cluster_identifier ==  args[:new_db]}.
        first

      if !dump_instance
        puts "Launching Database with identifier #{args[:new_db]}"
        latest_snapshot = client.describe_cluster_snapshots.snapshots.
          select { |snap| snap.cluster_identifier == args[:snapshot] }.
          sort { |s1,s2| s1.snapshot_create_time <=> s2.snapshot_create_time }.
          last

        dump_instance = client.restore_from_cluster_snapshot(
          cluster_identifier: args[:new_db],
          snapshot_identifier: latest_snapshot.snapshot_identifier,
          vpc_security_group_ids: [args[:security_group_id]]
        )
      else
        puts "Instance #{args[:new_db]} already exists"
      end
    end

    desc "Destroy a Redshift instance"
    task :destroy, [:id, :key, :region, :identifier] do |cmd, args|
      credentials = Aws::Credentials.new(args[:id], args[:key])
      client = Aws::Redshift::Client.new(region: args[:region], credentials: credentials)
      client.delete_cluster(cluster_identifier: args[:identifier], skip_final_cluster_snapshot: true)
    end

  end
end
