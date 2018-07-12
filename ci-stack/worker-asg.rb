require_relative '../lib/shared'

CloudFormation {
  version = external_parameters[:version]
  application_name = external_parameters[:application_name]
  project = external_parameters[:project]
  availability_zones = external_parameters[:availability_zones]
  version = external_parameters.fetch(:version)
  account_maps = external_parameters[:account_maps]
  app_settings = external_parameters[:app_settings]
  subnets = external_parameters[:stacks]['BuildASGStack'][:subnets]
  git_public_key = external_parameters[:git_public_key]

  default_tags =  render_aws_tags(external_parameters[:default_tags])

  asg_default_tags = [
    { Key: 'Name', Value: FnSub('${MasterStackName}-spot-worker-asg'), PropagateAtLaunch: true },
    { Key: 'Stack', Value: Ref('MasterStackName'), PropagateAtLaunch: true },
    { Key: 'Environment', Value: Ref('Environment'), PropagateAtLaunch: true },
  ]

  subnet_list = []
  availability_zones.each { |zone| subnet_list << Ref("PrivateSubnet#{zone}") }

  Metadata(
    Template: 'worker-spot-fleet',
    Description: 'This template sets up asg worker as spot',
    Project: project,
    Application: application_name,
    Version: version
  )

  AWSTemplateFormatVersion '2010-09-09'
  Description "#{project}/#{application_name} - App - #{version}"

  default_parameters.each { |parameter| Parameter(parameter) { Type 'String' } }

  %w[VPC ECSCluster BuildRole SecurityGroupAppInstance SecurityGroupWorkers BuildStorageFS].each { |parameter| Parameter(parameter) { Type 'String' } }

  Parameter('AsgSchedules') {
    Type 'String'
    AllowedValues ['on', 'off']
    Default 'on'
  }

  Condition('AsgSchedules', FnEquals(Ref('AsgSchedules'), 'on'))

  Mapping('AccountSettings', account_maps)
  Mapping('AppSettings', app_settings)

  private_subnets = []
  availability_zones.each do |az|
    Parameter("PrivateSubnet#{az}") { Type 'String' }
    private_subnets << Ref("PrivateSubnet#{az}")
  end

  InstanceProfile("InstanceProfile") {
    Path '/'
    Roles [Ref('BuildRole')]
  }

  LaunchConfiguration( :LaunchConfig ) {
    ImageId FnFindInMap('AppSettings', Ref('Environment'), 'BuildInstanceImageId')
    IamInstanceProfile Ref('InstanceProfile')
    KeyName FnFindInMap('AccountSettings', Ref('AWS::AccountId'), 'Ec2KeyPair')
    SecurityGroups [Ref('SecurityGroupAppInstance')]
    InstanceType FnFindInMap('AppSettings', Ref('Environment'),'WorkerSpotInstanceType')
    Property('SpotPrice', FnFindInMap('AppSettings', Ref('Environment'), 'WorkerSpotPrice'))
    Property('BlockDeviceMappings', [{ DeviceName: '/dev/xvda', Ebs: { VolumeSize: 20 } },
                                     { DeviceName: '/dev/xvdcz', Ebs: { VolumeSize: 50, VolumeType: 'gp2' } }])
    UserData FnBase64(FnJoin('', [
      "#!/bin/bash\n",
      "echo ECS_CLUSTER=", Ref('ECSCluster'), " >> /etc/ecs/ecs.config\n",
      "echo ECS_INSTANCE_ATTRIBUTES='{\"BuildGroup\": \"worker\"}' >> /etc/ecs/ecs.config\n",
      "stop ecs\n",
      "start ecs\n",
      "yum update -y \n",
      "sleep 30\n",
      "yum install -y git python-pip nfs-utils java-1.8.0-openjdk jq ruby24 nfs-utils awslogs \n",
      "curl https://amazon-ssm-ap-southeast-2.s3.amazonaws.com/latest/linux_amd64/amazon-ssm-agent.rpm -o /tmp/amazon-ssm-agent.rpm\n",
      "python-pip install --upgrade awscli\n",
      "yum install -y /tmp/amazon-ssm-agent.rpm\n",
      "curl -L https://github.com/barnybug/cli53/releases/download/0.8.12/cli53-linux-amd64 -o /usr/local/bin/cli53\n",
      "chmod a+x /usr/local/bin/cli53\n",
      "$(/usr/local/bin/aws ecr get-login --no-include-email --region ap-southeast-2)\n",
      "groupadd -g 1000 jenkins\n",
      "useradd -u 1000 -g 1000 -G docker jenkins\n",
      "echo jenkins ALL = NOPASSWD: ALL > /etc/sudoers.d/jenkins\n",
      "mkdir /home/jenkins/.ssh/\n",
      "cat >> /home/jenkins/.ssh/authorized_keys << EOF\n",
      "#{git_public_key}\n",
      "EOF\n",
      "chmod 700 /home/jenkins/.ssh\n",
      "chmod 600 /home/jenkins/.ssh/authorized_keys\n",
      "chown jenkins:jenkins -R /home/jenkins\n",
      "yum -y erase ntp || true\n",
      "sleep 10\n",
      "sudo yum -y install chrony\n",
      "sleep 10\n",
      "chkconfig chronyd on || true\n",
      "sudo service chronyd start || true\n",
      "export DNS_NAME=", FnJoin('', [ FnFindInMap('AccountSettings', Ref('AWS::AccountId'),'PrivateDNSDomain'), '.']), "\n",
      "export LOCAL_IP=`curl http://169.254.169.254/latest/meta-data/local-ipv4`\n",
      "export ZONE=`aws route53 list-hosted-zones | jq --arg dns_name ${DNS_NAME} -r '.HostedZones[] |   select(.Name == $dns_name and .Config.PrivateZone == true) | .Id | ltrimstr(\"/hostedzone/\")'`\n",
      "/usr/local/bin/cli53 rrcreate --replace ${ZONE} \"jenkins-worker 60 A ${LOCAL_IP}\"\n"
    ]))
  }

  AutoScalingGroup('BuildAutoScaleGroup') {
    AutoScalingGroupName FnSub('${MasterStackName}-spot-worker-asg')
    UpdatePolicy('AutoScalingRollingUpdate', {
      MinInstancesInService: '0',
      MaxBatchSize: '1',
    })
    LaunchConfigurationName Ref('LaunchConfig')
    HealthCheckGracePeriod '500'
    MinSize 1
    MaxSize 1
    DesiredCapacity 1
    Property('MetricsCollection', [{
      Granularity: '1Minute',
      Metrics: [
        'GroupDesiredCapacity',
        'GroupInServiceInstances',
        'GroupMaxSize',
        'GroupMinSize',
        'GroupPendingInstances',
        'GroupStandbyInstances',
        'GroupTerminatingInstances',
        'GroupTotalInstances'
      ]
    }])
    VPCZoneIdentifier subnet_list
    Property('Tags', asg_default_tags)
  }

  Resource('ScheduledActionUp') {
    Condition 'AsgSchedules'
    Type 'AWS::AutoScaling::ScheduledAction'
    Property('AutoScalingGroupName', Ref('BuildAutoScaleGroup'))
    Property('MinSize', '1')
    Property('MaxSize', '1')
    Property('DesiredCapacity', '1')
    Property('Recurrence', '0 20 * * 0-4')
  }

  Resource('ScheduledActionDown') {
    Condition 'AsgSchedules'
    Type 'AWS::AutoScaling::ScheduledAction'
    Property('AutoScalingGroupName', Ref('BuildAutoScaleGroup'))
    Property('MinSize', '0')
    Property('MaxSize', '0')
    Property('DesiredCapacity', '0')
    Property('Recurrence', '0 10 * * *')
  }
}
