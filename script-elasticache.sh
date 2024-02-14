#!/bin/bash
set -eux
region="us-east-1"
UtilizationThreshold="1.0"
output_file="recommendations-elasticache.csv"

echo "Resource, Engine, Deployment Option, Resource Name, Current Instance Type, Current Allocated Mem, Current Utilization, Current Hourly Cost, Target Instance Type, Target Allocated Memory, Expected Final Utilization, Final Hourly Cost (USD), Savings, Annual Savings, Nodes, Final Savings" > "$output_file"

# Function to fetch available Elasticache node types
fetch_available_elasticache_node_types() {
    #aws elasticache describe-cache-engine-versions --query 'CacheEngineVersions[].CacheParameterGroupFamily' --output json | jq -r '.[]'
    local instance_id=$1
    length=$(aws elasticache list-allowed-node-type-modifications --replication-group-id "$instance_id" --query 'ScaleDownModifications[]' --output json | jq length)
    if [ $length == "0" ]
    then
      echo "null"
    else
      aws elasticache list-allowed-node-type-modifications --replication-group-id "$instance_id" --query 'ScaleDownModifications[]' --output json | jq -r '.[]'
    fi

}

# Function to fetch hourly on-demand cost for an Elasticache node type
fetch_elasticache_node_type_cost() {
    local Engine=$1
    local instance_class=$2
    aws pricing --region us-east-1 get-products \
        --service-code AmazonElastiCache \
        --filters 'Type=TERM_MATCH,Field=cacheEngine,Value='"${Engine}" \
                  'Type=TERM_MATCH,Field=regionCode,Value='"${region}" \
                  'Type=TERM_MATCH,Field=instanceType,Value='"${instance_class}" \
        --query 'PriceList[0]' | jq -r > json
    cat json | jq -r .terms.OnDemand[].priceDimensions[].pricePerUnit.USD
}

fetch_elasticache_node_type_memory() {

    local Engine=$1
    local instance_class=$2
    aws pricing --region us-east-1 get-products \
        --service-code AmazonElastiCache \
        --filters 'Type=TERM_MATCH,Field=cacheEngine,Value='"${Engine}" \
                  'Type=TERM_MATCH,Field=regionCode,Value='"${region}" \
                  'Type=TERM_MATCH,Field=instanceType,Value='"${instance_class}" \
        --query 'PriceList[0]' | jq -r > json
    memory=$(cat json | jq -r .product.attributes.memory | sed "s/\bGiB\b//g")
    echo "scale=0; ${memory} / 1" | bc
}

# Function to fetch CloudWatch metric statistics
fetch_cloudwatch_metric() {
    local instance_id=$1
    local metric_name=$2
    local namespace=$3
    args=()

    nodes=($(aws elasticache describe-replication-groups --replication-group-id ${instance_id} --query 'ReplicationGroups[].MemberClusters[]'  --output json | jq -r '.[]'))

    local start_time=$(date -u -d '30 days ago' '+%Y-%m-%dT%H:%M:%SZ')
    local end_time=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    for node in "${nodes[@]}"; do

      Bytes=$(aws cloudwatch get-metric-statistics \
        --namespace "$namespace" \
        --metric-name "$metric_name" \
        --dimensions "Name=CacheClusterId,Value=$node" \
        --start-time "$start_time" \
        --end-time "$end_time" \
        --period 86400 \
        --statistics Maximum \
        --output json  | jq -r .Datapoints | jq 'map(select(.Unit == "Bytes") .Maximum) | min')
      bytestogb=1000000000
      z=$((Bytes / bytestogb))
      args+=("$z")
      #echo $z
    done
    maxfree=$(echo ${args[@]} | awk -v RS=" " '1' | sort -r | head -1)
    echo $maxfree
}

# Function to calculate percentage utilization
calculate_percentage_utilization() {
    local current_value=$1
    local total_value=$2

    if [ $total_value -eq 0 ]; then
        echo 0
    else
        echo "scale=4; ($current_value / $total_value)" | bc
    fi
}

# Fetch existing Elasticache clusters
elasticache_cluster_ids=($(aws elasticache describe-replication-groups --query 'ReplicationGroups[].ReplicationGroupId'  --output json | jq -r '.[]'))

# ElasticCache Recommendations
for instance_id in "${elasticache_cluster_ids[@]}"; do

    current_elastic_cache_node=($(aws elasticache describe-replication-groups --replication-group-id $instance_id --query 'ReplicationGroups[].CacheNodeType' --output json | jq -r '.[]'))
    current_elastic_cache_multiaz=($(aws elasticache describe-replication-groups --replication-group-id $instance_id --query 'ReplicationGroups[].MultiAZ' --output json | jq -r '.[]'))
    current_elastic_cache_nodes=($(aws elasticache describe-replication-groups --replication-group-id $instance_id --query 'ReplicationGroups[].MemberClusters[]' --output json | jq length))
    current_memory_free=($(fetch_cloudwatch_metric "$instance_id" "FreeableMemory" "AWS/ElastiCache"))
    node_1=$(aws elasticache describe-replication-groups --replication-group-id ${instance_id} --query 'ReplicationGroups[].MemberClusters[0]'  --output json | jq -r '.[]')
    cache_engine=$(aws elasticache describe-cache-clusters --cache-cluster-id ${node_1} --query 'CacheClusters[*].Engine' --output json | jq -r .[])
    current_cost_per_node=$(fetch_elasticache_node_type_cost ${cache_engine} ${current_elastic_cache_node})
    current_memory_allocated=$(fetch_elasticache_node_type_memory ${cache_engine} ${current_elastic_cache_node})
    current_memory_used=$((current_memory_allocated - current_memory_free))
    current_memory_utilization=$(calculate_percentage_utilization "$current_memory_used" "$current_memory_allocated")

    # Fetch available Elasticache node types
    elasticache_available_node_types=($(fetch_available_elasticache_node_types "$instance_id"))
    available_node_types=("${elasticache_available_node_types[@]}")

    if [ $available_node_types == null ]
    then
      echo "Can not be downgraded"
      echo "ElastiCache,$cache_engine,$current_elastic_cache_multiaz,$instance_id,$current_elastic_cache_node,$current_memory_allocated,$current_memory_utilization,$current_cost_per_node,$current_elastic_cache_node,$current_memory_allocated,$current_memory_utilization,$current_cost_per_node,0,0,$current_elastic_cache_nodes,0" >> "$output_file"
    else
      for target_node_type in "${available_node_types[@]}"; do
        target_memory_allocated=$(fetch_elasticache_node_type_memory ${cache_engine} ${target_node_type})
        target_memory_used=$((target_memory_allocated - current_memory_free))
        target_memory_utilization=$(calculate_percentage_utilization "$target_memory_used" "$target_memory_allocated")
        echo "Elastic Cache Instance ID: $instance_id"
        echo "Elastic Cache Current Node Type: $current_elastic_cache_node"
        echo "Elastic Cache MultiAZ: $current_elastic_cache_multiaz"
        echo "Elastic Cache Current Mem Free: $current_memory_free"
        echo "Elastic Cache Nodes: $current_elastic_cache_nodes"
        echo "Elastic Cache Engine: $cache_engine"
        echo "Elastic Cache Current Hourly Cost: $current_cost_per_node"
        echo "Elastic Cache Current Memory Allocated: $current_memory_allocated"
        echo "Elastic Cache Current Used: $current_memory_used"
        echo "Elastic Cache Current Utilization: $current_memory_utilization"
        echo "Elastic Cache Target Memory Allocated: $target_memory_allocated"
        echo "Elastic Cache Target Memory Used: $target_memory_used"
        echo "Elastic Cache Target Memory Utilization: $target_memory_utilization"
#        if (( $(bc <<< "$target_memory_utilization <  $current_memory_utilization"))); then
#           echo "$target_node_type is skipped as utilization is $target_memory_utilization, i.e less then current utlization $current_memory_utilization"
        if (( $(bc <<< "$target_memory_utilization >  $UtilizationThreshold"))); then
           echo "$target_node_type is skipped as utilization is $target_memory_utilization, i.e greater then $UtilizationThreshold"
        elif (( $(bc <<< "$target_memory_used < 0"))); then
           echo "$target_node_type is skipped as free memory $target_memory_used is less then 0"
        else
           # Fetch hourly on-demand cost
           hourly_cost=($(fetch_elasticache_node_type_cost ${cache_engine} ${target_node_type}))
           echo "Elastic Cache Recommendation:"
           echo "Elastic Cache Instance ID: $instance_id"
           echo "Expected Final Memory Utilization: $target_memory_utilization"  # Assuming target utilization is 60%
           echo "Hourly Cost: $hourly_cost"
           echo
           savings=$(echo  "scale=3; $current_cost_per_node - $hourly_cost" | bc)
           echo "Savings: $savings"
           if (( $(bc <<< "$savings < 0"))); then
             echo "Instance is not optimized for savings"
           else
              AnnualSavings=$(echo "scale=3; $savings * 8760" | bc)
              echo "AnnualSavings: $AnnualSavings"
              FinalSavings=$(echo "$AnnualSavings * $current_elastic_cache_nodes" | bc)
              echo "Final Savings: $FinalSavings"
              echo "ElastiCache,$cache_engine,$current_elastic_cache_multiaz,$instance_id,$current_elastic_cache_node,$current_memory_allocated,$current_memory_utilization,$current_cost_per_node,$target_node_type,$target_memory_allocated,$target_memory_utilization,$hourly_cost,$savings,$AnnualSavings,$current_elastic_cache_nodes,$FinalSavings" >> "$output_file"
           fi
        fi
      done
    fi
done
