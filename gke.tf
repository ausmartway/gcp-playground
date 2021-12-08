resource "google_service_account" "default" {
  account_id   = "service-account-for-nodepool"
  display_name = "Service Account for nodepool"
}

resource "google_container_cluster" "primary" {
  name     = "playground"
  location = "australia-southeast1"

  # We can't create a cluster with no node pool defined, but we want to only use
  # separately managed node pools. So we create the smallest possible default
  # node pool and immediately delete it. 

  remove_default_node_pool = true
  initial_node_count       = 1
}

resource "google_container_node_pool" "primary_preemptible_nodes" {
  name       = "playground-node-pool"
  location   = "australia-southeast1"
  cluster    = google_container_cluster.primary.name
  initial_node_count = 1
  autoscaling {
    min_node_count = 0
    max_node_count = 3
  }

  management {
    auto_repair = true
    auto_upgrade = true
  }

  node_config {
    preemptible  = true
    machine_type = "e2-medium"

    # Google recommends custom service accounts that have cloud-platform scope and permissions granted via IAM Roles.
    service_account = google_service_account.default.email
    oauth_scopes    = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
  }
}

resource "google_service_account" "dns01-solver" {
  account_id   = "dns01-solver"
  display_name = "dns01-solver"
}

resource "google_service_account_iam_binding" "admin-account-dns" {
  service_account_id = google_service_account.dns01-solver.name
  role               = "roles/dns.admin"
    members = [
    "serviceAccount:dns01-solver@$yulei-playground.iam.gserviceaccount.com",
  ]
}