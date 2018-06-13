require_relative '../lib/shared'

CloudFormation do
  version = external_parameters[:version]
  application_name = external_parameters[:application_name]
  project = external_parameters[:project]
  availability_zones = external_parameters[:availability_zones]
  version = external_parameters.fetch(:version)
  account_maps = external_parameters[:account_maps]
  app_settings = external_parameters[:app_settings]
  subnets = external_parameters[:subnets][:static]

  default_tags =  render_aws_tags(external_parameters[:default_tags])

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

  availability_zones.each_with_index do |zone, index|
    Resource("PrivateSubnet#{zone}") {
      Type 'AWS::EC2::Subnet'
      Property('VpcId', Ref('VPC'))
      Property('CidrBlock', FnSub("${CIDRPrefix}.#{subnets[index]}.0/${SubnetMask}"))
      Property('AvailabilityZone', FnSelect(index, FnGetAZs(Ref('AWS::Region')) ))
      Property('Tags',add_new_name_to_tags(default_tags, FnSub("${MasterStackName}-${Environment}-build-private#{zone}")))
    }
  end

  availability_zones.each do |az|
    Resource("SubnetRouteTableAssociationPrivate#{az}") {
      Type 'AWS::EC2::SubnetRouteTableAssociation'
      Property('SubnetId', Ref("PrivateSubnet#{az}"))
      Property('RouteTableId', Ref("RouteTablePrivate#{az}"))
    }
  end

  availability_zones.each do |zone|
    Output("PrivateSubnet#{zone}") {
      Value Ref("PrivateSubnet#{zone}")
    }
  end

end
