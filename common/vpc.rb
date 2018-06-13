require_relative '../lib/shared'

CloudFormation {
  version = external_parameters[:version]
  application_name = external_parameters[:application_name]
  project = external_parameters[:project]
  availability_zones = external_parameters[:availability_zones]
  application_name = external_parameters.fetch(:application_name)
  network_settings = external_parameters[:network_settings]
  default_parameters = external_parameters[:default_parameters]

  default_tags =  render_aws_tags(external_parameters[:default_tags])

  AWSTemplateFormatVersion '2010-09-09'
  Description "#{project}/#{application_name} - VPC Stack - #{version}"

  Metadata(
    Template: 'vpc',
    Description: 'This template sets up the vpc',
    Project: project,
    Application: application_name,
    Version: version,
  )

  default_parameters.each { |parameter| Parameter(parameter) { Type 'String' } }

  Mapping('NetworkSettings', network_settings)

  %w(CIDRPrefix SubnetMask).each { |parameter| Parameter(parameter) { Type 'String' } }

  Resource('VPC') do
    Type 'AWS::EC2::VPC'
    Property('CidrBlock', FnJoin('', [Ref('CIDRPrefix'), '.0.0/16']))
    #Property('InstanceTenancy', Ref('Tenancy'))
    Property('EnableDnsSupport', true)
    Property('EnableDnsHostnames', true)
    Property('Tags', default_tags)
  end

  availability_zones.each_with_index do |az, az_number|
    Resource("SubnetPublic#{az}") do
      Type 'AWS::EC2::Subnet'
      Property('VpcId', Ref('VPC'))
      Property('CidrBlock', FnSub("${CIDRPrefix}.#{az_number}.0/${SubnetMask}"))
      Property('AvailabilityZone', FnSelect(az_number, FnGetAZs(Ref( "AWS::Region"))))
      Property('Tags', add_new_name_to_tags(default_tags, FnSub("${MasterStackName}-public#{az}")))
    end
  end

  Resource('IGW') do
    Type 'AWS::EC2::InternetGateway'
    Property('Tags',add_new_name_to_tags(default_tags, FnSub('${MasterStackName}-igw')))
  end

  Resource('NACLPublic') do
    Type 'AWS::EC2::NetworkAcl'
    Property('VpcId', Ref('VPC'))
    Property('Tags',add_new_name_to_tags(default_tags, FnSub('${MasterStackName}-aclpublic')))
  end

  Resource('RouteTablePublic') do
    Type 'AWS::EC2::RouteTable'
    Property('VpcId', Ref('VPC'))
    Property('Tags',add_new_name_to_tags(default_tags, FnSub('${MasterStackName}-public')))
  end

  availability_zones.each do |az|
    Resource("RouteTablePrivate#{az}") do
      Type 'AWS::EC2::RouteTable'
      Property('VpcId', Ref('VPC'))
      Property('Tags',add_new_name_to_tags(default_tags, FnSub("${MasterStackName}-private#{az}")))
    end
  end

  availability_zones.each do |az|
    Resource("EIPNat#{az}") do
      DependsOn ['GWAttachmentIGW']
      Type 'AWS::EC2::EIP'
      Property('Domain', 'vpc')
    end
  end

  availability_zones.each do |az|
    Resource("NatGateway#{az}") do
      Type 'AWS::EC2::NatGateway'
      Property('AllocationId', FnGetAtt("EIPNat#{az}",'AllocationId'))
      Property('SubnetId', Ref("SubnetPublic#{az}"))
    end
  end

  Resource('GWAttachmentIGW') do
    DependsOn ['IGW']
    Type 'AWS::EC2::VPCGatewayAttachment'
    Property('VpcId', Ref('VPC'))
    Property('InternetGatewayId', Ref('IGW'))
  end

  Resource('RouteIGW') do
    Type 'AWS::EC2::Route'
    DependsOn ['GWAttachmentIGW']
    Property('RouteTableId', Ref('RouteTablePublic'))
    Property('DestinationCidrBlock', '0.0.0.0/0')
    Property('GatewayId',Ref('IGW'))
  end

  availability_zones.each do |az|
    Resource("RoutePrivateNatGateway#{az}") do
      DependsOn ["NatGateway#{az}"]
      Type 'AWS::EC2::Route'
      Property('RouteTableId', Ref("RouteTablePrivate#{az}"))
      Property('DestinationCidrBlock', '0.0.0.0/0')
      Property('NatGatewayId', Ref("NatGateway#{az}"))
    end
  end

  availability_zones.each do |az|
    Resource("SubnetRouteTableAssociation#{az}") do
      Type 'AWS::EC2::SubnetRouteTableAssociation'
      Property('SubnetId', Ref("SubnetPublic#{az}"))
      Property('RouteTableId', Ref('RouteTablePublic'))
    end
  end

  # can move this to use share lib logic "cidrator"
  public_acls.each do |acl|
    cidr = case acl[:CidrBlock]
      when 'wholestack'
        FnJoin('', [Ref('CIDRPrefix'), '.0.0/16'])
      when 'public'
        FnFindInMap('NetworkSettings', Ref('Environment'), 'InboundExternalIPRange')
      else
        acl[:CidrBlock]
      end
      
    Resource(acl[:name]) do
      Type 'AWS::EC2::NetworkAclEntry'
      Property('CidrBlock', cidr)
      Property('Egress', acl[:Egress]) if acl[:Egress]
      Property('Protocol', acl[:Protocol])
      Property('RuleAction', acl[:RuleAction])
      Property('RuleNumber', acl[:RuleNumber])
      Property('PortRange',{
        From: acl[:PortRangeStart],
        To: acl[:PortRangeFinish]
      })
      Property('NetworkAclId', Ref('NACLPublic'))
    end
  end

  all_route_tables = [Ref('RouteTablePublic')]
  availability_zones.each do |az|
    all_route_tables << Ref("RouteTablePrivate#{az}")
  end

  availability_zones.each do |az|
    Resource("SubnetNetworkAclAssociationPublic#{az}") do
      Type 'AWS::EC2::SubnetNetworkAclAssociation'
      Property('SubnetId', Ref("SubnetPublic#{az}"))
      Property('NetworkAclId', Ref('NACLPublic'))
    end
  end

  Resource('ProductionVpcFlowLogsServiceRole') do
    Type 'AWS::IAM::Role'
    Property('AssumeRolePolicyDocument', {
      Version: '2012-10-17',
      Statement: [
        {
          Sid: 'AllowFlowLogs',
          Effect: 'Allow',
          Principal: { Service: 'vpc-flow-logs.amazonaws.com'},
          Action: [ 'sts:AssumeRole' ]
        }
      ]
    })
    Property('Path','/')
    Property('Policies', [
      {
        PolicyName: 'cloudwatchlogsrole',
        PolicyDocument: {
          Version: '2012-10-17',
          Statement: [
            {
              Action: [
                'logs:CreateLogGroup',
                'logs:CreateLogStream',
                'logs:PutLogEvents',
                'logs:DescribeLogGroups',
                'logs:DescribeLogStreams'
              ],
              Effect: 'Allow',
              Resource: '*'

            }
          ]
        }
      }
    ])
  end

  Resource('S3VPCEndpoint') do
    Type 'AWS::EC2::VPCEndpoint'
    Property('PolicyDocument', {
      Version: '2012-10-17',
      Statement: [{
        Effect: 'Allow',
        Principal: '*',
        Action: ['s3:*'],
        Resource: ['arn:aws:s3:::*']
      }]
    })
    Property('RouteTableIds', all_route_tables)
    Property('ServiceName', FnSub('com.amazonaws.${AWS::Region}.s3'))
    Property('VpcId',  Ref('VPC'))
  end

  Resource('DynamoVPCEndpoint') do
    Type 'AWS::EC2::VPCEndpoint'
    Property('PolicyDocument', {
      Version:'2012-10-17',
      Statement: [{
        Effect: 'Allow',
        Principal: '*',
        Action: ['dynamodb:*'],
        Resource: ['arn:aws:dynamodb:::*']
      }]
    })
    Property('RouteTableIds', all_route_tables)
    Property('ServiceName', FnSub('com.amazonaws.${AWS::Region}.dynamodb'))
    Property('VpcId',  Ref('VPC'))
  }

  Resource('ProductionVpcFlowLog') {
    Type 'AWS::EC2::FlowLog'
    Property('DeliverLogsPermissionArn', FnGetAtt('ProductionVpcFlowLogsServiceRole','Arn'))
    Property('LogGroupName', FnJoin( '', [ Ref('MasterStackName'), '-VPC-FlowLog']))
    Property('ResourceId', Ref('VPC'))
    Property('ResourceType', 'VPC')
    Property('TrafficType', 'ALL')
  }

  Resource('FlowLogGroup') {
    Type 'AWS::Logs::LogGroup'
    Property('RetentionInDays', '7')
  }

  Resource('ProductionVpcFlowLogStream') {
    Type 'AWS::Logs::LogStream'
    Property('LogGroupName', Ref('FlowLogGroup'))
    #LogStreamName
  }

  Output('VPC') {
    Value(Ref('VPC'))
  }

  availability_zones.each do |az|
    Output("SubnetPublic#{az}") {
      Value(Ref("SubnetPublic#{az}"))
    }
  end

  Output('RouteTablePublic') {
    Value(Ref('RouteTablePublic'))
  }

  availability_zones.each do |az|
    Output("RouteTablePrivate#{az}") {
      Value(Ref("RouteTablePrivate#{az}"))
    }
  end

}
