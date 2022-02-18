

lib_path = File.expand_path(File.dirname(File.dirname(__FILE__)))
unless $LOAD_PATH.any? {|p| File.expand_path(p) == lib_path}
  $LOAD_PATH.unshift(lib_path)
end
require 'collections'
require 'common'
require 'cgi'

require "ibm_vpc"
require 'pry-byebug'

module BushSlicer
  class IBMCloud
    include Common::Helper
    include CollectionsIncl
    attr_reader :config, :vpc, :regions
    attr_accessor :region

    def initialize(**opts)
      @config = conf[:services, opts.delete(:service_name) || :ibmcloud]
      authenticator = IbmVpc::Authenticators::IamAuthenticator.new(
        apikey: @config[:auth][:apikey]
      )
      @vpc = IbmVpc::VpcV1.new(authenticator: authenticator)

    end

    # @return Array of region hash
    # {"name"=>"us-south", "href"=>"https://us-south.iaas.cloud.ibm.com/v1/regions/us-south", "endpoint"=>"https://us-south.iaas.cloud.ibm.com", "status"=>"available"}
    def regions
      @regions ||= self.vpc.list_regions.result['regions']
    end

    # @return Hash containing region information
    def region(name)
      region_hash = self.regions.select {|r| r['name'] == name}.first
      raise "Unsupported region '#{name}" unless region_hash
      return region_hash
    end

    def region=(reg_name)
      region_info = self.region(reg_name)
      self.vpc.service_url = region_info['endpoint'] + "/v1"
    end

    def instances
      start = nil
      instances = []
      loop do
        response = self.vpc.list_instances(start: start)
        instances += response.result["instances"]

        next_link = response.result.dig("next", "href")
        break if next_link.nil?

        start = CGI.parse(URI(next_link).query)["start"].first
      end
      return instances
    end
    # ibm.regions.select {|r| r['name'] == 'us-south'}.first
    # class Instance
    #   include Common::BaseHelper

    #   attr_reader :connection, :id, :region

    #   # @param spec [Hash] provide at least "InstanceId" and "RegionId" keys
    #   def initialize(spec, connection)
    #     @connection = connection
    #     @id = spec["InstanceId"].freeze
    #     @region = spec["RegionId"].freeze
    #     update spec
    #   end

    #   def update(spec)
    #     if id == spec["InstanceId"] || region == spec["RegionId"]
    #       @spec = spec
    #     else
    #       raise "trying to update instance with wrong spec: #{id}/#{region}" \
    #         "vs #{spec["InstanceId"]}/#{spec["RegionId"]}"
    #     end
    #   end

    #   private def known_region?
    #     @spec&.dig()
    #   end

    #   def spec(cached: true)
    #     unless cached && @spec
    #       res = connection.request(
    #         action: "DescribeInstances",
    #         params: {
    #           "InstanceIds" => [id].to_json,
    #           "RegionId" => region
    #         }
    #       )
    #       @spec = res[:parsed]["Instances"]["Instance"].first
    #       unless @spec
    #         raise ResourceNotFound, "no instnaces with id #{id} found"
    #       end
    #     end
    #     return @spec
    #   end

    #   def exists?
    #     status(cached: false) != "Deleted"
    #   end

    #   def status(cached: true)
    #     spec(cached: cached)["Status"]
    #   rescue ResourceNotFound
    #     "Deleted"
    #   end

    #   # @return [String]
    #   def public_ip(cached: true)
    #     public_ips(cached: cached)&.first
    #   end

    #   def public_ips(cached: true)
    #     spec(cached: cached).dig("PublicIpAddress", "IpAddress")
    #   end

    #   def private_ip(cached: true)
    #     private_ips(cached: cached)&.first
    #   end

    #   def private_ips(cached: true)
    #     if !spec(cached: cached).dig("InnerIpAddress", "IpAddress").empty?
    #       spec(cached: true).dig("InnerIpAddress", "IpAddress")
    #     else
    #       spec(cached: true).dig("VpcAttributes", "PrivateIpAddress", "IpAddress")
    #     end
    #   end

    #   def name(cached: true)
    #     spec(cached: cached)["InstanceName"]
    #   end

    #   # @param wait [Boolean, Numeric] seconds to wait for instance to stop
    #   # @param graceful [Boolean] when true method will not raise when instance
    #   #   is missing or is already stopped/stopping
    #   def stop!(graceful: true, force: false, wait: true)
    #     params = {
    #       "InstanceId" => id,
    #       "ForceStop" => !!force.to_s,
    #       "ConfirmStop" => !!force.to_s
    #     }
    #     res = connection.request(
    #       action: "StopInstance",
    #       params: params,
    #       noraise: graceful,
    #     )

    #     unless res[:success]
    #       # if we are here then graceful is true
    #       if res[:exitstatus] == 404 || res[:exitstatus] == 403 && res[:parsed]["Code"] == "IncorrectInstanceStatus"
    #         return nil
    #       else
    #         raise RequestError, "Failed to stop instance #{instance_id}: " \
    #           "#{res[:response]}"
    #       end
    #     end

    #     if wait
    #       timeout = Numeric === wait ? wait : 60
    #       success = wait_for(timeout, interval: 5) {
    #         status(cached: false) == "Stopped"
    #       }
    #       unless success
    #         raise BushSlicer::TimeoutError,
    #           "Timeout waiting for instance #{id} to stop. Status: #{status}"
    #       end
    #       return nil
    #     else
    #       return res[:parsed]["RequestId"]
    #     end
    #   end

    #   # @see #stop!
    #   # @see https://www.alibabacloud.com/help/doc-detail/25507.htm
    #   def delete!(graceful: true, wait: true)
    #     res = connection.request(
    #       action: "DeleteInstance",
    #       params: {"InstanceId" => id},
    #       noraise: graceful,
    #     )

    #     unless res[:success]
    #       # if we are here then graceful is true
    #       if res[:exitstatus] == 404
    #         return nil
    #       elsif res[:exitstatus] == 403 && res[:parsed]["Code"].include?("Status")
    #         stop!(force: true, graceful: true, wait: true)
    #         return delete!(graceful: false, wait: wait)
    #       else
    #         raise RequestError, "Failed to delete instance #{instance_id}: " \
    #           "#{res[:response]}"
    #       end
    #     end

    #     if wait
    #       timeout = Numeric === wait ? wait : 60
    #       success = wait_for(timeout, interval: 5) {
    #         status(cached: false) == "Deleted"
    #       }
    #       unless success
    #         raise BushSlicer::TimeoutError,
    #           "Timeout waiting to delete instance #{id}. Status: #{status}"
    #       end
    #       return nil
    #     else
    #       return res[:parsed]["RequestId"]
    #     end
    #   end
    # end
  end
end

if __FILE__ == $0
  extend BushSlicer::Common::Helper
  ibm = BushSlicer::IBMCloud.new
  insts2 = ibm.instances
  binding.pry
  print inst2

end

