require 'set'
require 'text-table'
require 'thread'
require 'openshift_qe_slack'
#require 'pry-byebug'

module BushSlicer

  # base class to display a cloud resource .

  class ResourceMonitor
    attr_accessor :slack

    def print_summary()
      print("Resoruce summary...")
    end

    # @returns a list of users' slack user_ids and list of unknown users
    def translate_to_slack_users(users: nil, slack_client:)
      # 1. get the slacker_users lookup map
      users_map_hash = slack_client.build_user_map
      # 2. separate valid users from unknown into their buckets
      users_hash = validate_users(users_map: users_map_hash.keys, users_list: users)

      slack_user_ids = users_hash[:valid].map { |u| "<@#{users_map_hash.dig(u)}>" }
      [slack_user_ids.join(" "), users_hash[:unknown].join(" ")]
    end

    # @return Boolean (true if overlimit)
    def over_limit?(resource_type: nil, resource_value:nil, resource_limit:nil, percentage: 95)
      if resource_value/resource_limit.to_f * 100 > percentage
        msg = "#{resource_type} count #{resource_value} is over #{percentage}% of limit #{resource_limit}\n"
        return msg
      else
        return nil
      end
    end

    def notify_limits(limits_msgs)

      limits_msgs.each do |msg|
        print(msg)
        send_to_slack(summary_text: msg)
      end
    end
    # call Slack webhook to send text to a particular channel.
    # slack channel URL is defined in private/config/config.yaml
    ## TODO: research doing it via ruby-slack-client instead
    def send_to_slack(summary_text: text, options: nil)
      @slack ||= BushSlicer::CoreosSlack.new(channel: '#ocpqe_cloud_usage')
      @slack.post_msg(msg: summary_text, as_blocks: true)
    end
  end

  class AwsResources < ResourceMonitor
    attr_accessor :amz

    def initialize(svc_name: "AWS-CLOUD-USAGE")
      @amz = Amz_EC2.new(service_name: svc_name)
      @limits = {:s3 => 300, :vpcs => 200}
      @table = Text::Table.new
    end
    ## print out summary in a text table format
    def print_summary(data_rows, headers)
      table = Text::Table.new

      table.head = headers
      data_rows.each do |data|
        table.rows << data
      end
      puts table
    end

    def get_vpcs(global_region: :"AWS-CLOUD-USAGE")
      regions = @amz.get_regions
      region_names =  regions.map {|r| r.region_name }
      vpcs_hash  = {}
      raw_vpcs = []
      mutex = Mutex.new
      threads = []
      regions.each do | region |
        threads << Thread.new(region.region_name) do |region_name|
          begin
            aws = Amz_EC2.new(service_name: global_region, region: region_name)
            vpcs_in_region = aws.get_vpcs()
            mutex.synchronize do
              raw_vpcs << vpcs_in_region
              if vpcs_in_region.count > 0
                vpcs_hash[region.region_name] = vpcs_in_region
              end
            end
          rescue => e
            puts "WARNING: failed to get VPCs for region #{region_name}: #{e.message}"
          end
        end
      end
      threads.each(&:join)
      ### uncomment the following if not using thread
      # regions.each do | region |
      #   aws = Amz_EC2.new(service_name: global_region, region: region.region_name)
      #   vpcs_in_region = aws.get_vpcs()
      #   if vpcs_in_region.count > 0
      #     vpcs_hash[region.region_name] = vpcs_in_region
      #   end
      # end
      return vpcs_hash, raw_vpcs
    end

    # @return an array of ['name', 'date']
    def extract_vpcs_data(raw_vpcs)
      vpcs = raw_vpcs.flatten
      data = []
      target_data = ['openshift_creationDate', 'Name', "expirationDate"]
      vpcs.each do |vpc|
        row_data_hash = {}
        vpc.tags.each do |tag|
          if tag.key == 'Name' or tag.key == 'openshift_creationDate'
            row_data_hash[tag.key] = tag.value
          end
        end
        data << row_data_hash
      end
      s_data = data.select {|d| d.has_key? 'Name' and d.has_key? "openshift_creationDate"}
      data_list = []
      s_data.each do |data|
        data_list<< [data['Name'], data['openshift_creationDate']]
      end
      return data_list
    end

    # @instances <Array of unordered Instance obj>
    def summarize_resources(resources: ['s3, vpc'])
      vpcs_hash, raw_vpcs = self.get_vpcs
      vpcs_total = 0
      summary_data = []
      limits_msgs = []

      vpcs_limit = @limits[:vpcs]
      s3_buckets_limits = @limits[:s3]
      vpcs_hash.each do |region, vpcs|
        vpcs_total += vpcs.count
        row_data = [region, vpcs.count]
        summary_data<< row_data
        limits_msg = over_limit?(resource_type: "vpc in region #{region}",resource_value: vpcs.count, resource_limit: vpcs_limit, percentage: 80)
        limits_msgs << limits_msg unless limits_msg.nil?
      end
      vpcs_header = ['region', 'total']
      print_summary(summary_data, vpcs_header)
      vpcs_name_date_list = extract_vpcs_data(raw_vpcs)
      vpcs_name_date_header = ['name', 'creation_date']
      print_summary(vpcs_name_date_list, vpcs_name_date_header)

      s3_buckets = @amz.s3_list_buckets
      s3_limits_msg = over_limit?(resource_type: "s3 buckets", resource_value: s3_buckets.count, resource_limit: s3_buckets_limits, percentage: 90)
      limits_msgs << s3_limits_msg unless s3_limits_msg.nil?
      notify_limits(limits_msgs)
      print("VPCS total: #{vpcs_total}\n")
      print("S3 bucket total: #{s3_buckets.count}\n")

    end


  end

  class GceResources < ResourceMonitor
    attr_accessor :gce

    def initialize(jenkins: nil)
      @gce = GCE.new
      @resource_limits = {
        :instances => 1000,
        :cpus => 5000,
        :disks => 2000,
        :networks => 100
      }
    end

    # @return Array of networks (VPCs)
    def get_networks
      gce = @gce
      project = gce.config[:project]
      compute = gce.compute
      networks = compute.list_networks(project)
      return networks.items || []
    end

    # @return Array of [name, creation_timestamp, subnet_count]
    def extract_networks_data(networks)
      data = []
      networks.each do |network|
        subnet_count = network.subnetworks ? network.subnetworks.count : 0
        row_data = [
          network.name,
          network.creation_timestamp || 'N/A',
          subnet_count
        ]
        data << row_data
      end
      return data
    end

    ## print out summary in a text table format
    def print_summary(data_rows, headers)
      table = Text::Table.new

      table.head = headers
      data_rows.each do |data|
        table.rows << data
      end
      puts table
    end

    # @return Hash of instances keyed by zone
    def get_instances_by_zone
      gce = @gce
      project = gce.config[:project]
      regions = gce.regions
      instances_hash = {}
      raw_instances = []
      mutex = Mutex.new
      threads = []

      regions.each do |region, zones|
        zones.each do |zone|
          threads << Thread.new(zone) do |zone_name|
            begin
              instances_in_zone = gce.get_instances_by_status(zone: zone_name, status: 'RUNNING')
              mutex.synchronize do
                raw_instances << instances_in_zone
                if instances_in_zone && instances_in_zone.count > 0
                  instances_hash[zone_name] = instances_in_zone
                end
              end
            rescue => e
              puts "WARNING: failed to get instances for zone #{zone_name}: #{e.message}"
            end
          end
        end
      end
      threads.each(&:join)
      return instances_hash, raw_instances
    end

    # @return Array of [name, status, creation_date, machine_type]
    def extract_instances_data(raw_instances)
      instances = raw_instances.flatten.compact
      data = []
      instances.each do |inst|
        row_data = [
          inst.name,
          inst.status,
          inst.creation_timestamp,
          inst.machine_type.split('/')[-1]
        ]
        data << row_data
      end
      return data
    end

    # @return summary of GCE resources
    def summarize_resources(resources: [])
      instances_hash, raw_instances = self.get_instances_by_zone
      instances_total = 0
      summary_data = []
      limits_msgs = []

      instances_hash.each do |zone, instances|
        instances_total += instances.count
        row_data = [zone, instances.count]
        summary_data << row_data
        limits_msg = over_limit?(resource_type: "instances in zone #{zone}",
                                 resource_value: instances.count,
                                 resource_limit: @resource_limits[:instances],
                                 percentage: 80)
        limits_msgs << limits_msg unless limits_msg.nil?
      end

      zone_header = ['zone', 'total_instances']
      print_summary(summary_data, zone_header)

      instances_data = extract_instances_data(raw_instances)
      instances_header = ['name', 'status', 'creation_date', 'machine_type']
      print_summary(instances_data, instances_header)

      instances_limits_msg = over_limit?(resource_type: "total instances",
                                        resource_value: instances_total,
                                        resource_limit: @resource_limits[:instances],
                                        percentage: 90)
      limits_msgs << instances_limits_msg unless instances_limits_msg.nil?

      # Get and display networks (VPCs)
      networks = self.get_networks
      networks_data = extract_networks_data(networks)
      networks_header = ['name', 'creation_date', 'subnet_count']
      print_summary(networks_data, networks_header)

      networks_limits_msg = over_limit?(resource_type: "total networks (VPCs)",
                                         resource_value: networks.count,
                                         resource_limit: @resource_limits[:networks],
                                         percentage: 90)
      limits_msgs << networks_limits_msg unless networks_limits_msg.nil?

      # IAM policy member breakdown
      begin
        iam_summary = get_iam_policy_summary

        iam_role_data = iam_summary[:by_role].map { |role, members| [role, members.count] }
        print_summary(iam_role_data, ['role', 'member_count'])

        iam_type_data = iam_summary[:by_type].map { |type, count| [type, count] }
        print_summary(iam_type_data, ['member_type', 'count'])
      rescue => e
        puts "WARNING: failed to get IAM policy: #{e.message}"
        iam_summary = nil
      end

      print("#" * 70 + "\n")
      msg_header = "# GCE usage summary\n"
      print("#{msg_header}")
      print("#" * 70 + "\n")
      print("Total instances: #{instances_total}/#{@resource_limits[:instances]}\n")
      print("Total networks (VPCs): #{networks.count}/#{@resource_limits[:networks]}\n")
      if iam_summary
        print("Total unique IAM members: #{iam_summary[:total_unique]}\n")
      end

      limits_msgs.unshift(msg_header) if limits_msgs.count > 0
      notify_limits(limits_msgs)
    end

    def get_iam_policy_summary
      policy = @gce.get_iam_policy
      by_role = {}
      all_members = Set.new

      policy.bindings.each do |binding|
        role_short = binding.role.split('/').last
        by_role[role_short] = binding.members
        binding.members.each { |m| all_members.add(m) }
      end

      by_type = Hash.new(0)
      all_members.each do |member|
        type = member.split(':').first
        by_type[type] += 1
      end

      { by_role: by_role, by_type: by_type, total_unique: all_members.count }
    end

  end

  class AzureResources < ResourceMonitor
    attr_accessor :azure

    def initialize(jenkins: nil)
      @azure = Azure.new
    end

    def summarize_resources(cm)
      print "Summaring resource ..."
    end

  end


  class OpenstackResources < ResourceMonitor
    attr_accessor :os, :tenant_usage

    def initialize()
      @os = OpenStack.new
      ### these are limits for the resources in our Openstack.
      @resource_limits = {
        :instances => 800,
        :rams => 4.4,  # unit is TB
        :volumes => 1000,
        :vcpus => 2400,
        :volume_snapshots => 200,
        :volume_storage => 14.6,
        :security_group_rules => 3000
      }
    end

    def summarize_resources(resources: [])
      @tenant_usage = self.os.get_tenant_usage
      usage = {}
      ## compute resources
      usage[:instances] = self.os.get_instances_usage
      usage[:vcpus] = self.os.get_vcpus_usage
      usage[:rams] = self.os.get_ram_usage
      ## volume resources
      usage[:volumes] = self.os.get_volume_usage
      usage[:volume_snapshots] = self.os.get_volume_snapshots_usage
      usage[:volume_storage] = self.os.get_volume_storage_usage
      ## Network only Security Group Rules has a limit.
      print("#" * 70 + "\n")
      msg_header = "# Openstack usage summary\n"
      print("#{msg_header}")
      print("#" * 70 + "\n")
      limits_msgs = []
      usage.each do |k, v|
        if v.size == 1
          unit = ""
        else
          unit = v[1]
        end
        limits_msg = over_limit?(resource_type: "#{k}",
                                 resource_value: v[0],
                                 resource_limit: @resource_limits[k],
                                 percentage: 95)
        limits_msgs << limits_msg unless limits_msg.nil?
        print("#{k}: #{v[0]}#{unit}/#{@resource_limits[k]}#{unit}\n")
      end
      # add the header so the limit message has more context
      limits_msgs.unshift(msg_header) if limits_msgs.count > 0
      notify_limits(limits_msgs)
    end

  end

  class PacketResources < ResourceMonitor
    attr_accessor :packet

    def initialize(jenkins: nil)
      @packet = Packet.new
    end

    # instances is <Array> of server objects
    def summarize_instances(instances)
      summary = []
    end

  end


  class VSphereResources < ResourceMonitor
    attr_accessor :vms

    def initialize(profile_name="vsphere_vmc7-qe", jenkins: nil)
      @vms = BushSlicer::VSphere.new(service_name: profile_name)
    end

    # instances is <Array> of server objects
    def summarize_resource(instances)
    end

  end

  class AliCloudResources < ResourceMonitor
    attr_accessor :ali
    def initialize(svc_name: :alicloud-v4, jenkins: nil)
      @ali = Alicloud.new(service_name: svc_name, region: 'us-east-1')
    end

    # @instances <Array of unordered Instance obj>
    def summarize_resource(region, instances)
      summary = []
      ali = @ali
    end
  end
end
