#!/usr/bin/env ruby

''"
Helper utility to interact with AWS services on the command-line
"''

# Fast path for --version/--help before loading heavy deps
if ARGV == ['--version']
  puts "CloudWatch 0.0.1"
  exit
end

$LOAD_PATH.unshift("#{File.dirname(__FILE__)}/../lib")
$LOAD_PATH.unshift("#{File.dirname(__FILE__)}/../tools")

require 'commander'
require 'collections'
require 'common'
require 'text-table'
require 'launchers/cloud_helper'



module BushSlicer
  class CloudWatch
    include Commander::Methods
    include Common::Helper
    include Common::CloudHelper
    attr_accessor :amz, :gce, :azure

    # TODO: perhaps we can cache the jenkins id mapping into a db instead to
    # to save time
    def initialize
      always_trace!
    end

    def run
      program :name, 'CloudWatch'
      program :version, '0.0.1'
      program :description, 'Helper utility to alert the team when'
      global_option('--no_slack') do |_f|
        no_slack = true
      end
      default_command :help

      command :aws do |c|
        c.syntax = "#{File.basename __FILE__} -r <aws_region_name> [--all]"
        c.description = 'display resource summary for AWS'
        c.action do |args, options|
          require 'launchers/amz'
          require 'cucuhttp'
          require 'jenkins_api_client'
          require 'resource_monitor'
          ps = AwsResources.new
          options.config = conf
          say 'Getting summary...'
          ps.summarize_resources
        end
      end

      command :openstack do |c|
        c.syntax = "#{File.basename __FILE__}"
        c.description = 'display resource summary for Openstack'
        c.action do |args, options|
          require 'launchers/openstack'
          require 'cucuhttp'
          require 'resource_monitor'
          ps = OpenstackResources.new
          options.config = conf
          say 'Getting summary...'
          ps.summarize_resources
        end
      end

      command :gce do |c|
        c.syntax = "#{File.basename __FILE__}"
        c.description = 'display resource summary for GCE'
        c.action do |args, options|
          require 'launchers/gce'
          require 'cucuhttp'
          require 'resource_monitor'
          ps = GceResources.new
          options.config = conf
          say 'Getting summary...'
          ps.summarize_resources
        end
      end

      run!
    end
  end
end

BushSlicer::CloudWatch.new.run if __FILE__ == $0
