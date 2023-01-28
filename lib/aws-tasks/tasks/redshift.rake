require 'aws-sdk-redshift'

namespace :aws do
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
