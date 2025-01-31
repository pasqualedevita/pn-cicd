#!/usr/bin/env bash
    
set -Eeuo pipefail
trap cleanup SIGINT SIGTERM ERR EXIT

cleanup() {
  trap - SIGINT SIGTERM ERR EXIT
  # script cleanup here
}

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)


usage() {
      cat <<EOF
    Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [-p <aws-profile>] -r <aws-region> -e <env-type> -i <github-commitid> [-c <custom_config_dir>] -b <artifactBucketName>

    [-h]                      : this help message
    [-v]                      : verbose mode
    [-p <aws-profile>]        : aws cli profile (optional)
    -r <aws-region>           : aws region as eu-south-1
    -e <env-type>             : one of dev / uat / svil / coll / cert / prod
    -i <github-commitid>      : commitId for github repository pagopa/pn-infra
    [-c <custom_config_dir>]  : where tor read additional env-type configurations
    -b <artifactBucketName>   : bucket name to use as temporary artifacts storage
    
EOF
  exit 1
}

parse_params() {
  # default values of variables set from params
  project_name=pn
  work_dir=$HOME/tmp/poste_deploy
  custom_config_dir=""
  aws_profile=""
  aws_region=""
  env_type=""
  pn_infra_commitid=""
  bucketName=""
  LambdasBucketName=""

  while :; do
    case "${1-}" in
    -h | --help) usage ;;
    -v | --verbose) set -x ;;
    -p | --profile) 
      aws_profile="${2-}"
      shift
      ;;
    -r | --region) 
      aws_region="${2-}"
      shift
      ;;
    -e | --env-name) 
      env_type="${2-}"
      shift
      ;;
    -i | --infra-commitid) 
      pn_infra_commitid="${2-}"
      shift
      ;;
    -c | --custom-config-dir) 
      custom_config_dir="${2-}"
      shift
      ;;
    -w | --work-dir) 
      work_dir="${2-}"
      shift
      ;;
    -b | --bucket-name) 
      bucketName="${2-}"
      shift
      ;;
    -B | --lambda-bucket-name) 
      LambdasBucketName="${2-}"
      shift
      ;;
    -?*) die "Unknown option: $1" ;;
    *) break ;;
    esac
    shift
  done

  args=("$@")

  # check required params and arguments
  [[ -z "${env_type-}" ]] && usage 
  [[ -z "${pn_infra_commitid-}" ]] && usage
  [[ -z "${bucketName-}" ]] && usage
  [[ -z "${aws_region-}" ]] && usage
  [[ -z "${LambdasBucketName-}" ]] && usage
  return 0
}

dump_params(){
  echo ""
  echo "######      PARAMETERS      ######"
  echo "##################################"
  echo "Project Name:       ${project_name}"
  echo "Work directory:     ${work_dir}"
  echo "Custom config dir:  ${custom_config_dir}"
  echo "Infra CommitId:     ${pn_infra_commitid}"
  echo "Env Name:           ${env_type}"
  echo "AWS region:         ${aws_region}"
  echo "AWS profile:        ${aws_profile}"
  echo "Bucket Name:        ${bucketName}"
  echo "Lambda Bucket Name: ${LambdasBucketName}"
}


# START SCRIPT

parse_params "$@"
dump_params


cd $work_dir


echo "=== Download pn-infra" 
if ( [ ! -e pn-infra ] ) then 
  git clone https://github.com/pagopa/pn-infra.git
fi

echo ""
echo "=== Checkout pn-infra commitId=${pn_infra_commitid}"
( cd pn-infra && git fetch && git checkout $pn_infra_commitid )
echo " - copy custom config"
if ( [ ! -z "${custom_config_dir}" ] ) then
  cp -r $custom_config_dir/pn-infra .
fi

echo ""
echo "=== Base AWS command parameters"
aws_command_base_args=""
if ( [ ! -z "${aws_profile}" ] ) then
  aws_command_base_args="${aws_command_base_args} --profile $aws_profile"
fi
if ( [ ! -z "${aws_region}" ] ) then
  aws_command_base_args="${aws_command_base_args} --region  $aws_region"
fi
echo ${aws_command_base_args}


templateBucketS3BaseUrl="s3://${bucketName}/pn-infra/${pn_infra_commitid}"
templateBucketHttpsBaseUrl="https://s3.${aws_region}.amazonaws.com/${bucketName}/pn-infra/${pn_infra_commitid}/runtime-infra"
echo " - Bucket Name: ${bucketName}"
echo " - Bucket Template S3 Url: ${templateBucketS3BaseUrl}"
echo " - Bucket Template HTTPS Url: ${templateBucketHttpsBaseUrl}"


echo ""
echo "=== Upload files to bucket"
aws ${aws_command_base_args} \
    s3 cp pn-infra $templateBucketS3BaseUrl \
      --recursive --exclude ".git/*"


echo ""
echo ""
echo ""
echo "###                  LOGS BUCKET INFO                  ###"
echo "##########################################################"

logsBucketName=$( aws ${aws_command_base_args} \
    cloudformation describe-stacks --stack-name pn-ipc-${env_type} \
      | jq -r '.Stacks[0].Outputs | .[] | select(.OutputKey=="LogsBucketName") | .OutputValue' )

logsExporterRoleArn=$( aws ${aws_command_base_args} \
    cloudformation describe-stacks --stack-name pn-ipc-${env_type} \
      | jq -r '.Stacks[0].Outputs | .[] | select(.OutputKey=="LogsExporterRoleArn") | .OutputValue' )

lambdasBucketName=$( aws ${aws_command_base_args} \
    cloudformation describe-stacks --stack-name pn-ipc-${env_type} \
      | jq -r '.Stacks[0].Outputs | .[] | select(.OutputKey=="LambdasBucketName") | .OutputValue' )

lambdasBasePath=$( aws ${aws_command_base_args} \
    cloudformation describe-stacks --stack-name pn-ipc-${env_type} \
      | jq -r '.Stacks[0].Outputs | .[] | select(.OutputKey=="LambdasBasePath") | .OutputValue' )

echo "LOGS Bucker: ${logsBucketName}"
echo "LOGS Role Arn: ${logsExporterRoleArn}"
echo "LambdasBucketName: ${lambdasBucketName}"
echo "LambdasBasePath: ${lambdasBasePath}"


echo "=== Prepare parameters for pn-logs-export.yaml deployment in $env_type ACCOUNT"
TemplateFilePath="pn-infra/runtime-infra/pn-logs-export.yaml"
ParamFilePath="pn-infra/runtime-infra/pn-logs-export-${env_type}-cfg.json"
EnanchedParamFilePath="pn-logs-export-${env_type}-cfg-enhanced.json"


PreviousOutputFilePath="previous-output-${env_type}.json"
echo " - PreviousOutputFilePath: ${PreviousOutputFilePath}"
echo " - TemplateFilePath: ${TemplateFilePath}"
echo " - ParamFilePath: ${ParamFilePath}"
echo " - EnanchedParamFilePath: ${EnanchedParamFilePath}"
echo " ==== Directory listing"

echo ""
echo "= Read Outputs from previous stack adding new parameters"
aws ${aws_command_base_args} \
    cloudformation describe-stacks \
      --stack-name pn-ipc-$env_type \
      --query "Stacks[0].Outputs" \
      --output json \
      | jq 'map({ (.OutputKey): .OutputValue}) | add' \
      | jq ".TemplateBucketBaseUrl = \"$templateBucketHttpsBaseUrl\"" \
      | jq ".LambdasBucketName= \"$lambdasBucketName\"" \
      | jq ".LambdasBasePath = \"$lambdasBasePath\"" \
      | jq ".ProjectName = \"$project_name\"" \
      | jq ".Version = \"cd_scripts_commitId=${cd_scripts_commitId},pn_infra_commitId=${pn_infra_commitid}\"" \
      | tee ${PreviousOutputFilePath}

echo ""
echo "= Enanched parameters file"
jq -s "{ \"Parameters\": .[0] } * .[1]" ${PreviousOutputFilePath} ${ParamFilePath} \
   > ${EnanchedParamFilePath}
cat ${EnanchedParamFilePath}


aws ${aws_command_base_args} cloudformation deploy \
      --stack-name pn-logs-export-${env_type} \
      --capabilities CAPABILITY_NAMED_IAM \
      --template-file "$TemplateFilePath" \
      --parameter-overrides file://$(realpath $EnanchedParamFilePath)
