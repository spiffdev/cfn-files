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

  default_parameters = external_parameters[:default_parameters]
  default_tags_map = external_parameters[:default_tags]

  default_tags = []
  default_tags_map.each do |tag|
    default_tags << {Key: tag[:key], Value: Ref(tag[:ref])}
  end

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

  %w(VPC RouteTablePublic CIDRPrefix SubnetMask SecurityGroupWeb).each { |parameter| Parameter(parameter) { Type 'String' } }

  Parameter('AsgSchedules') {
    Type 'String'
    AllowedValues ['on', 'off']
    Default 'on'
  }

  Condition('AsgSchedules', FnEquals(Ref('AsgSchedules'), 'on'))

  availability_zones.each do |az|
    Parameter("RouteTablePrivate#{az}") { Type 'String' }
    Parameter("SubnetPublic#{az}") { Type 'String' }
  end

  availability_zones.each_with_index do |zone, index|
    Resource("PrivateSubnet#{zone}") {
      Type 'AWS::EC2::Subnet'
      Property('VpcId', Ref('VPC'))
      Property('CidrBlock', FnJoin('', [Ref('CIDRPrefix'), '.', subnets[index], ".0/", Ref('SubnetMask')]))
      Property('AvailabilityZone', FnSelect(index, FnGetAZs(Ref( "AWS::Region" )) ))
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

  Resource('EcsElasticLoadBalancerForECS') {
    Type 'AWS::ElasticLoadBalancingV2::LoadBalancer'
    Property('Subnets', public_subnets)
    Property('SecurityGroups', [Ref('SecurityGroupWeb')])
    Property('LoadBalancerAttributes', [
      { Key: 'access_logs.s3.enabled', Value: true },
      { Key: 'access_logs.s3.bucket',  Value: FnImportValue('account-S3ELBAccessLogsBucket') },
      { Key: 'access_logs.s3.prefix', Value: 'Logs/AWSLogs/JenkinsMaster' },
      { Key: 'idle_timeout.timeout_seconds', Value: 60}
    ])
    Property('Tags', add_new_name_to_tags(default_tags, FnSub('${MasterStackName}-${Environment}-application-loadbalancer')))
  }

  Resource('BuildStorageFS') {
    Type 'AWS::EFS::FileSystem'
    Property('Encrypted', true)
    Property('FileSystemTags', add_new_name_to_tags(default_tags, FnSub('${MasterStackName}-BuildStorage')))
    Property('PerformanceMode', 'generalPurpose')
  }

  availability_zones.each do |az|
    Resource("MasterStorageMountTarget#{az}") {
      Type 'AWS::EFS::MountTarget'
      Property('FileSystemId', Ref('BuildStorageFS'))
      Property('SecurityGroups', [Ref('MountTargetSecurityGroup')])
      Property('SubnetId', Ref("PrivateSubnet#{az}"))
    }
  end

  Resource('MountTargetSecurityGroup') {
    Type 'AWS::EC2::SecurityGroup'
    Property('VpcId', Ref('VPC'))
    Property('GroupDescription', 'Security group for mount target for build stack')
    Property('SecurityGroupIngress', [{ IpProtocol: 'tcp', FromPort: '2049',ToPort: '2049',CidrIp: FnJoin("", [Ref('CIDRPrefix'), '.0.0/16']), Description: 'SG for EFS Mount'}])
  }

  Output('BuildStorageFS') {
    Value Ref('BuildStorageFS')
  }

  Output('DNSName') {
    Value FnGetAtt('EcsElasticLoadBalancerForECS', 'DNSName')
  }

  Output('ZoneId') {
    Value FnGetAtt('EcsElasticLoadBalancerForECS', 'CanonicalHostedZoneID')
  }

  Output('EcsElasticLoadBalancer') {
    Value Ref('EcsElasticLoadBalancerForECS')
  }

  availability_zones.each do |zone|
    Output("PrivateSubnet#{zone}") {
      Value Ref("PrivateSubnet#{zone}")
    }
  end

end