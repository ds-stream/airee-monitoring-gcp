#!/bin/bash
# params

while getopts p:r:l:n:m:s:o:i:e:t: flag
do
    case "${flag}" in
        p) tmp_project_id=${OPTARG};;
        r) tmp_monitor_cluster_name=${OPTARG};;
        o) tmp_gh_org=${OPTARG};;
        l) tmp_gke_node_location=${OPTARG};;
        n) tmp_gke_node_num=${OPTARG};;
        m) tmp_gke_machine_type=${OPTARG};;
        s) tmp_sa_name=${OPTARG};;
        i) tmp_replica_num=${OPTARG};;
        e) tmp_network_name=${OPTARG};;
        t) tmp_subnetwork_name=${OPTARG};;
    esac
done


# target vars with default values:
project_id="${tmp_project_id}"
monitor_cluster_name="${tmp_monitor_cluster_name:-monitoring}" # Default
gke_region="${tmp_gke_region:-us-central1}" # Default
gke_node_location="${tmp_gke_node_location:-us-central1-c}" # Default
gke_node_num="${tmp_gke_node_num:-2}" # Default
gke_machine_type="${tmp_gke_machine_type:-e2-standard-2}" # Default
sa_name="${tmp_sa_name:-monitor-sa}" # Default
replica_num="${tmp_replica_num:-2}" # Default
network_name="${tmp_network_name}"
subnetwork_name="${tmp_subnetwork_name:-sub-${tmp_network_name}}" # Default


# Check applications that we will need
# check if user have a gcloud
echo "Checking gcloud"
if ! command -v gcloud version 2> /dev/null
then
    echo "gcloud could not be found"
    exit 1
else
    echo "gcloud OK"
fi
# check if user have a kubectl
echo "Checking kubectl"
if ! command -v kubectl version --client=true 2> /dev/null
then
    echo "kubectl could not be found"
    exit 1
else
    echo "kubectl OK"
fi

# Check if user is connected to gcp and project exists
if [[ $(gcloud projects list --filter="project_id:${project_id}") != "" ]]
then
    echo "Project ${project_id} exists, set project as default"
    gcloud config set project ${project_id}
else
    echo "Project ${project_id} not exists or user not logged"
    exit 1
fi

# # Enable services for Ariee-Monitoring
# echo "Enable required services for Airee-Monitoring"
# # Secrets
# gcloud services enable secretmanager.googleapis.com
# # servicenetworking
# gcloud services enable servicenetworking.googleapis.com
# # IAM
# gcloud services enable iamcredentials.googleapis.com
# gcloud services enable iam.googleapis.com
# # domain
# gcloud services enable domains.googleapis.com
# gcloud services enable dns.googleapis.com 
# # deploymentmanager
# gcloud services enable deploymentmanager.googleapis.com
# # gcr
# gcloud services enable artifactregistry.googleapis.com
# gcloud services enable containersecurity.googleapis.com
# gcloud services enable containerregistry.googleapis.com
# # k8s
# gcloud services enable containerfilesystem.googleapis.com
# gcloud services enable container.googleapis.com
# gcloud services enable autoscaling.googleapis.com
# gcloud services enable cloudresourcemanager.googleapis.com
# # cloud
# gcloud services enable cloudasset.googleapis.com
# gcloud services enable cloudbuild.googleapis.com
# # MCS - multi cluster services
# gcloud services enable gkehub.googleapis.com
# gcloud services enable multiclusteringress.googleapis.com
# gcloud services enable trafficdirector.googleapis.com
# gcloud services enable multiclusterservicediscovery.googleapis.com

# # turn on multi-cluster-services
# gcloud container fleet multi-cluster-services enable

# Check network

if [[ $(gcloud compute networks list --filter="name:${network_name}") != "" ]]
then
    echo "Network ${network_name} exists"
    read -p "Are you sure you want to use it? [Y/n] " -n 1 -r
    echo "" # move to a new line
    if [[ ! $REPLY =~ ^[Yy]$ ]]
    then
        exit 1
    fi
else
    echo "Creating Network ${network_name}"
    gcloud compute networks create ${network_name} \
        --subnet-mode=custom
fi

if [[ $(gcloud compute networks subnets list --network=${network_name} --filter="name:${subnetwork_name}") != "" ]]
then
    echo "Subnetwork ${subnetwork_name} exists"
    read -p "Are you sure you want to use it? [Y/n] " -n 1 -r
    echo    # move to a new line
    if [[ ! $REPLY =~ ^[Yy]$ ]]
    then
        exit 1
    fi
else
    echo "Creating Subnetwork ${subnetwork_name}"
    gcloud compute networks subnets create ${subnetwork_name} \
        --network=${network_name} \
        --range="10.2.0.0/16" \
        --region="${gke_region}"
fi

# Check if cluster exists if not create one
if [[ $(gcloud container clusters list --filter="name:${monitor_cluster_name}") != "" ]]
then
    echo "Cluster ${monitor_cluster_name} exists, update to provided conf"
    gcloud container clusters update ${monitor_cluster_name} \
        --region="${gke_region}" \
        --node-locations="${gke_node_location}"
    gcloud container clusters update ${monitor_cluster_name} \
        --region="${gke_region}" \
        --workload-pool="${project_id}.svc.id.goog"
    gcloud container clusters resize -q ${monitor_cluster_name} \
        --region ${gke_region} \
        --node-pool "default-pool" \
        --num-nodes ${gke_node_num}
    # Machine type cant be change in place, new pool needs to be created
else
    echo "Cluster ${monitor_cluster_name} not exists, creating cluster"
    gcloud container clusters create ${monitor_cluster_name} \
        --region ${gke_region} \
        --node-locations ${gke_node_location} \
        --num-nodes ${gke_node_num} \
        --machine-type "${gke_machine_type}" \
        --workload-pool="${project_id}.svc.id.goog" \
        --network="${network_name}" \
        --subnetwork="${subnetwork_name}"
fi

# role binding for MSC

gcloud projects add-iam-policy-binding infra-sandbox-352609 \
    --member "serviceAccount:${project_id}.svc.id.goog[gke-mcs/gke-mcs-importer]" \
    --role "roles/compute.networkViewer"

# Adding cluster to fleet for MCS

if [[ $(gcloud container fleet memberships list --filter="name:${monitor_cluster_name}") != "" ]]
then
    echo "Fleet membership with name ${monitor_cluster_name}"
    read -p "Are you sure you want to use it? If not it will be recreated. Answer Y- keep configuration, n- recreate membership. [Y/n] " -n 1 -r
    echo    # move to a new line
    if [[ $REPLY =~ ^[Nn]$ ]]
    then
        echo "Delete and create membership"
        gcloud container fleet memberships delete ${monitor_cluster_name} --quiet
        gcloud container fleet memberships register ${monitor_cluster_name} \
            --gke-cluster ${gke_region}/${monitor_cluster_name} \
            --enable-workload-identity \
            --project=${project_id}
    elif [[ $REPLY =~ ^[Yy]$ ]]
    then
        echo "Keeping current configuration"
    else
        echo "Wrong answer, exit 1"
        exit 1
    fi
else
    gcloud container fleet memberships register ${monitor_cluster_name} \
        --gke-cluster ${gke_region}/${monitor_cluster_name} \
        --enable-workload-identity \
        --project=${project_id}
fi

# configure kubectl
gcloud container clusters get-credentials ${monitor_cluster_name} --region ${gke_region}

# deploy monitoring
kubectl apply -k ./kustomization/