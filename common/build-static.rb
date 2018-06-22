require_relative '../lib/shared'

CloudFormation do
  version = external_parameters[:version]
  application_name = external_parameters[:application_name]
  project = external_parameters[:project]
  availability_zones = external_parameters[:availability_zones]
  version = external_parameters.fetch(:version)
  account_maps = external_parameters[:account_maps]
  app_settings = external_parameters[:app_settings]
  region = external_parameters['region']
  subnets = external_parameters[:subnets][region]

  static_subnets = subnets.select { |name,h| h[:static] }
  default_tags = render_aws_tags(external_parameters[:default_tags])

  subnet_list = []
  availability_zones.each { |zone| subnet_list << Ref("PrivateSubnet#{zone}") }

  public_subnets = []
  availability_zones.each do |az|
    Parameter("SubnetPublic#{az}") { Type 'String' }
    public_subnets << Ref("SubnetPublic#{az}")
  end

  Metadata(
    Template: 'build-static',
    Description: 'This template sets up static things so that as other stacks may depend on the outputs',
    Project: project,
    Application: application_name,
    Version: version
  )

  AWSTemplateFormatVersion '2010-09-09'
  Description "#{project}/#{application_name} - Build Static - #{version}"

  Mapping('AccountSettings', account_maps)
  Mapping('AppSettings', app_settings)

  default_parameters.each { |parameter| Parameter(parameter) { Type 'String' } }

  %w[VPC RouteTablePublic CIDRPrefix SubnetMask SecurityGroupWeb].each { |parameter| Parameter(parameter) { Type 'String' } }

  availability_zones.each do |az|
    Parameter("RouteTablePrivate#{az}") { Type 'String' }
    Parameter("SubnetPublic#{az}") { Type 'String' }
  end

  static_subnets.each do |name, subnet_config|
    subnet_config[:subnets].each_with_index do |(zone, cidr), index|
      Resource("#{name}Subnet#{zone}") do
        Type 'AWS::EC2::Subnet'
        Property('VpcId', Ref('VPC'))
        Property('CidrBlock', FnSub("${CIDRPrefix}.#{cidr}.0/${SubnetMask}"))
        # Property('AvailabilityZone', FnSelect(index, FnGetAZs(Ref('AWS::Region')) ))
        Property('AvailabilityZone', "#{region}#{zone.downcase}")
        Property('Tags',add_new_name_to_tags(default_tags, FnSub("${MasterStackName}-${Environment}-#{name}Subnet#{zone}")))
      end

      Resource("#{name}SubnetRouteTableAssociationPrivate#{zone}") do
        Type 'AWS::EC2::SubnetRouteTableAssociation'
        Property('SubnetId', Ref("#{name}Subnet#{zone}"))
        Property('RouteTableId', Ref("RouteTablePrivate#{zone}"))
      end

      Output("#{name}Subnet#{zone}") do
        Value Ref("#{name}Subnet#{zone}")
      end
    end
  end
end

# :subnets:
#   region:
#     Private:
#       :static: true
#       :subnets:
#         A: 3
#         B: 4
#         C: 5
#     Rds:
#       :static: true
#       :subnets:
#         A: 12
#         B: 13
#         C: 14
#     Test:
#       :static: false
#       :subnets:
#         A: 15
#         B: 16
#         C: 17