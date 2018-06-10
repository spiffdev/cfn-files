require_relative '../lib/shared'

CloudFormation {
  version = external_parameters[:version]
  application_name = external_parameters[:application_name]
  project = external_parameters[:project]
  availability_zones = external_parameters[:availability_zones]
  version = external_parameters.fetch(:version)
  account_maps = external_parameters[:account_maps]
  default_parameters = external_parameters[:default_parameters]
  timezone = external_parameters[:timezone]

  AWSTemplateFormatVersion '2010-09-09'
  Description "#{project}/#{application_name} - ECS Task for Jenkins Master - #{version}"

  Metadata(
    Template: 'jenkins-master',
    Description: 'This template sets up the jenkins master',
    Project: project,
    Application: application_name,
    Version: version
  )

  default_parameters.each { |parameter| Parameter(parameter) { Type 'String' } }

  %w[VPC RoleName ECSCluster SecurityGroupWeb 
     Image Tag EcsServiceRoleForTasks
     DNSName ZoneId EcsElasticLoadBalancer].each { |parameter| Parameter(parameter) { Type 'String' } }

  availability_zones.each do |az|
    Parameter("SubnetPublic#{az}") { Type 'String' }
  end

  Mapping('AccountSettings', account_maps)

  jenkins_container_def = {
    Name: FnSub('${MasterStackName}-jenkins-master'),
    Memory: 1500,
    Cpu: 300,
    Image: FnJoin('', [Ref('Image'), ':', Ref('Tag')]),
    PortMappings: [{ ContainerPort: 8080 }],
    Environment: [{ Name: 'JAVA_OPTS', Value: "-Xmx1024m -Duser.timezone=#{timezone}" }],
    Essential: true,
    MountPoints: [{ ContainerPath: '/etc/localtime', SourceVolume: 'timezone', ReadOnly: true },
                  { ContainerPath: '/var/jenkins_home', SourceVolume: 'jenkins_home', ReadOnly: false }]
  }

  jenkins_volumes = [{ Name: 'timezone',
                       Host: { SourcePath: '/etc/localtime' } },
                     { Name: 'jenkins_home',
                       Host: { SourcePath: '/mnt/efs/data/jenkins' } }]

  Resource('JenkinsMasterTaskDef') do
    Type 'AWS::ECS::TaskDefinition'
    Property('Family', FnSub('${MasterStackName}-jenkins-master'))
    Property('ContainerDefinitions', [jenkins_container_def])
    Property('Volumes', jenkins_volumes)
  end

  Resource('JenkinsMasterService') do
    DependsOn %w[HttpsListener TargetGroup]
    Type 'AWS::ECS::Service'
    Property('ServiceName', FnSub('${MasterStackName}-jenkins-master'))
    Property('Cluster', Ref('ECSCluster'))
    Property('DesiredCount', 1)
    Property('DeploymentConfiguration', MinimumHealthyPercent: 0, MaximumPercent: 200)
    Property('Role', Ref('EcsServiceRoleForTasks'))
    Property('TaskDefinition', Ref('JenkinsMasterTaskDef'))
    Property('LoadBalancers', [{ ContainerName: FnSub('${MasterStackName}-jenkins-master'),
                                 ContainerPort: '8080',
                                 TargetGroupArn: Ref('TargetGroup') }])
    Property('PlacementConstraints', [{ Type: 'memberOf', Expression: 'attribute:BuildGroup == master' }, { Type: 'distinctInstance' }])
  end

  certificate_from_map = FnJoin('', ['arn:aws:acm:', Ref('AWS::Region'), ':', Ref('AWS::AccountId'), ':',
                                     FnFindInMap('AccountSettings', Ref('AWS::AccountId'), 'Cert')])

  Resource('HttpsListener') do
    Type 'AWS::ElasticLoadBalancingV2::Listener'
    Property('Certificates', [{ CertificateArn: certificate_from_map }])
    Property('DefaultActions', [{ Type: 'forward', TargetGroupArn: Ref('TargetGroup') }])
    Property('LoadBalancerArn', Ref('EcsElasticLoadBalancer'))
    Property('Port', '443')
    Property('Protocol', 'HTTPS')
  end

  Resource('TargetGroup') do
    Type 'AWS::ElasticLoadBalancingV2::TargetGroup'
    Property('Name', FnSub('JenkinsMaster-${MasterStackName}'))
    Property('Port', '8080')
    Property('Protocol', 'HTTP')
    Property('VpcId', Ref('VPC'))
    Property('HealthCheckPath', '/login')
  end

  Resource('ELBRecordSet') do
    Type 'AWS::Route53::RecordSet'
    Property('HostedZoneName', FnJoin('', [FnFindInMap('AccountSettings', Ref('AWS::AccountId'), 'DNSDomain'), '.']))
    Property('Name', FnJoin('', ['jenkins.', FnFindInMap('AccountSettings', Ref('AWS::AccountId'), 'DNSDomain'), '.']))
    Property('Type','A')
    Property('AliasTarget', DNSName: Ref('DNSName'), HostedZoneId: Ref('ZoneId'))
  end

}
