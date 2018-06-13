require_relative '../lib/shared'

CloudFormation {
  version = external_parameters[:version]
  application_name = external_parameters[:application_name]
  project = external_parameters[:project]
  version = external_parameters.fetch(:version)
  securitygroups = external_parameters.fetch(:securitygroups)
  network_settings = external_parameters[:network_settings]
  default_parameters = external_parameters[:default_parameters]

  default_tags =  render_aws_tags(external_parameters[:default_tags])

  AWSTemplateFormatVersion '2010-09-09'
  Description "#{project}/#{application_name} - Security Groups - #{version}"

  Metadata(
    Template: 'security-groups',
    Description: 'This template sets up security groups',
    Project: project,
    Application: application_name,
    Version: version,
  )

  default_parameters.each { |parameter| Parameter(parameter) { Type 'String' } }

  %w(VPC CIDRPrefix SubnetMask).each { |parameter| Parameter(parameter) { Type 'String' } }

  Mapping('NetworkSettings', network_settings)

  outputs = []

  securitygroups.each do |securitygroup, details|
    outputs << securitygroup

    ingress_rules = []
    details[:ingress].each do |rule|
      protocol = rule[:protocol] || 'tcp'
      cidr = cidrator(rule[:cidr])
      ingress_rules << { IpProtocol: protocol, FromPort: rule[:from], ToPort: rule[:to], CidrIp: cidr, Description: rule[:description]}
    end

    egress_rules = []
    if details[:egress]
      details[:egress].each do |rule|
        protocol = rule[:protocol] || 'tcp'
        cidr = cidrator(rule[:cidr])
        egress_rules << { IpProtocol: protocol, FromPort: rule[:from], ToPort: rule[:to], CidrIp: cidr, Description: rule[:description]}
      end
    end

    Resource(securitygroup) {
      Type 'AWS::EC2::SecurityGroup'
      Property('VpcId', Ref('VPC'))
      Property('GroupDescription', details[:description])
      Property('SecurityGroupIngress', ingress_rules)
      Property('SecurityGroupEgress', egress_rules)
      Property('Tags',Property('Tags', add_new_name_to_tags(default_tags, FnSub("${MasterStackName}-#{securitygroup}"))))
    }
  end

   outputs.each do |ref|
     Output(ref) {
       Value(Ref(ref))
     }
   end
}
