require_relative '../lib/shared'

CloudFormation {
  version = external_parameters[:version]
  application_name = external_parameters[:application_name]
  project = external_parameters[:project]
  version = external_parameters.fetch(:version)
  default_parameters = external_parameters[:default_parameters]

  # TAGS unsupported
  # default_tags =  render_aws_tags(external_parameters[:default_tags])

  AWSTemplateFormatVersion '2010-09-09'
  Description "#{project}/#{application_name} - ECS Cluster - #{version}"

  Metadata(
    Template: 'ecs-cluster',
    Description: 'This template sets up the ecs cluster - good guess!',
    Project: project,
    Application: application_name,
    Version: version,
  )

  default_parameters.each { |parameter| Parameter(parameter) { Type 'String' } }

  Resource("ECSCluster") {
    Type 'AWS::ECS::Cluster'
    Property('ClusterName', FnSub('${MasterStackName}-ECS-Cluster'))
    # TAGS unsupported
  }

  Output('ECSCluster') {
    Value(Ref('ECSCluster'))
  }
}
