#!/bin/bash

# Function to fetch CloudWatch metric statistics
fetch_cloudwatch_metric() {
    local resource_id=$1
    local metric_name=$2
    local namespace=$3

    local start_time=$(date -u -d '30 days ago' '+%Y-%m-%dT%H:%M:%SZ')
    local end_time=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    aws cloudwatch get-metric-statistics \
        --namespace "$namespace" \
        --metric-name "$metric_name" \
        --dimensions "Name=InstanceId,Value=$resource_id" \
        --start-time "$start_time" \
        --end-time "$end_time" \
        --period 86400 \
        --statistics Average \
        --output json | jq -r '.Datapoints | sort_by(.Timestamp) | last(.[]).Average'
}

# Function to calculate percentage utilization
calculate_percentage_utilization() {
    local current_value=$1
    local total_value=$2

    if [ $total_value -eq 0 ]; then
        echo 0
    else
        echo "scale=2; ($current_value / $total_value) * 100" | bc
    fi
}

# Function to suggest instance type based on utilization
suggest_instance_type() {
    local current_utilization=$1
    local threshold_utilization=$2
    local available_instance_types=("${@:3}")

    local suggested_instance_type=""
    
    for instance_type in "${available_instance_types[@]}"; do
        suggested_utilization_candidate=$(calculate_expected_final_utilization "$current_utilization" "$instance_type")
        if (( $(echo "$suggested_utilization_candidate < $threshold_utilization" | bc -l) )); then
            suggested_instance_type=$instance_type
            break
        fi
    done

    echo "$suggested_instance_type"
}

# Function to calculate expected final utilization after resizing
calculate_expected_final_utilization() {
    local current_utilization=$1
    local new_instance_type=$2

    # You would need to customize this logic based on how the new instance type affects utilization
    # For simplicity, let's assume a linear relationship for demonstration purposes
    local utilization_factor=0.8  # Adjust this factor based on your specific scenario

    echo "scale=2; $current_utilization * $utilization_factor" | bc
}

# Output file
output_file="recommendations.csv"

# Fetch existing EC2 instances
ec2_instance_ids=($(aws ec2 describe-instances --query 'Reservations[*].Instances[*].InstanceId' --output json | jq -r '.[][] | select(.InstanceId != null) | .InstanceId'))

# Fetch existing RDS instances
rds_instance_ids=($(aws rds describe-db-instances --query 'DBInstances[*].DBInstanceIdentifier' --output json | jq -r '.[]'))

# Fetch existing Elasticache clusters
elasticache_cluster_ids=($(aws elasticache describe-cache-clusters --query 'CacheClusters[*].CacheClusterId' --output json | jq -r '.[]'))

# Create CSV file and write header
echo "Resource,Current Utilization,Recommended Instance Type,Expected Final Utilization" > "$output_file"

# EC2 Recommendations
for instance_id in "${ec2_instance_ids[@]}"; do
    current_memory_utilization=$(fetch_cloudwatch_metric "$instance_id" "MemoryUtilization" "System/Linux")
    suggested_ec2_instance_type=$(suggest_instance_type "$current_memory_utilization" 60 "t3.micro" "t3.small" "t3.medium")
    expected_final_ec2_utilization=$(calculate_expected_final_utilization "$current_memory_utilization" "$suggested_ec2_instance_type")

    echo "EC2 Recommendation:"
    echo "Current Memory Utilization: $current_memory_utilization%"
    echo "Suggested Instance Type: $suggested_ec2_instance_type"
    echo "Expected Final Memory Utilization: $expected_final_ec2_utilization%"
    echo

    echo "EC2,$current_memory_utilization,$suggested_ec2_instance_type,$expected_final_ec2_utilization" >> "$output_file"
done

# RDS Recommendations
for instance_id in "${rds_instance_ids[@]}"; do
    current_memory_utilization=$(fetch_cloudwatch_metric "$instance_id" "MemoryUtilization" "AWS/RDS")
    suggested_rds_instance_type=$(suggest_instance_type "$current_memory_utilization" 60 "db.t3.micro" "db.t3.small" "db.t3.medium")
    expected_final_rds_utilization=$(calculate_expected_final_utilization "$current_memory_utilization" "$suggested_rds_instance_type")

    echo "RDS Recommendation:"
    echo "Current Memory Utilization: $current_memory_utilization%"
    echo "Suggested Instance Type: $suggested_rds_instance_type"
    echo "Expected Final Memory Utilization: $expected_final_rds_utilization%"
    echo

    echo "RDS,$current_memory_utilization,$suggested_rds_instance_type,$expected_final_rds_utilization" >> "$output_file"
done

# Elasticache Recommendations
for cluster_id in "${elasticache_cluster_ids[@]}"; do
    current_memory_utilization=$(fetch_cloudwatch_metric "$cluster_id" "MemoryUtilization" "AWS/ElastiCache")
    suggested_elasticache_instance_type=$(suggest_instance_type "$current_memory_utilization" 60 "cache.t3.micro" "cache.t3.small" "cache.t3.medium")
    expected_final_elasticache_utilization=$(calculate_expected_final_utilization "$current_memory_utilization" "$suggested_elasticache_instance_type")

    echo "Elasticache Recommendation:"
    echo "Current Memory Utilization: $current_memory_utilization%"
    echo "Suggested Instance Type: $suggested_elasticache_instance_type"
    echo "Expected Final Memory Utilization: $expected_final_elasticache_utilization%"
    echo

    echo "Elasticache,$current_memory_utilization,$suggested_elasticache_instance_type,$expected_final_elasticache_utilization" >> "$output_file"
done

echo "Recommendations written to $output_file"
