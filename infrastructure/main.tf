# === 1. GEREKLİ API'LERI AKTİF ETME ===
terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

# GCP sağlayıcısının yapılandırılması
provider "google" {
  project = "ozan-gcp-demo"
  region  = "europe-west3" # Ana bölgeyi burada tanımlıyoruz
}

# Değişkenleri tek bir yerde topluyoruz
locals {
  project_id = "ozan-gcp-demo"
  region     = "europe-west3" # Tüm kaynaklar için bu bölgeyi kullanacağız
}


# Gerekli servislerin etkinleştirilmesi
resource "google_project_service" "compute_api" {
  service            = "compute.googleapis.com"
  disable_on_destroy = false
}
resource "google_project_service" "sql_api" {
  service            = "sqladmin.googleapis.com"
  disable_on_destroy = false
}
resource "google_project_service" "vpc_api" {
  service            = "vpcaccess.googleapis.com"
  disable_on_destroy = false
}
resource "google_project_service" "networking_api" {
  service            = "servicenetworking.googleapis.com"
  disable_on_destroy = false
}
resource "google_project_service" "run_api" {
  service            = "run.googleapis.com"
  disable_on_destroy = false
}
resource "google_project_service" "cloud_build_api" {
  service            = "cloudbuild.googleapis.com"
  disable_on_destroy = false
}
resource "google_project_service" "artifact_api" {
  service            = "artifactregistry.googleapis.com"
  disable_on_destroy = false
}
resource "google_project_service" "secretmanager_api" {
  service            = "secretmanager.googleapis.com"
  disable_on_destroy = false
}

# === 2. AĞ (VPC) AYARLAMALARI (SIFIRDAN OLUŞTURMA) ===

# Kendi özel VPC ağımızı oluşturuyoruz
resource "google_compute_network" "main_vpc" {
  name                    = "main-vpc"
  auto_create_subnetworks = false # Best practice: Alt ağları biz yöneteceğiz
  depends_on              = [google_project_service.compute_api]
}

# Connector ve servislerimizin yaşayacağı bir alt ağ (subnet) oluşturuyoruz
resource "google_compute_subnetwork" "main_subnet" {
  name          = "main-subnet"
  ip_cidr_range = "10.0.0.0/28" # Sadece bu alt ağ için küçük bir aralık
  region        = local.region  # Değişkeni kullan
  network       = google_compute_network.main_vpc.id
}

# Cloud SQL için özel IP alabilmesi için bir IP aralığı oluşturma
resource "google_compute_global_address" "private_ip_range" {
  name          = "private-ip-range-for-sql"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.main_vpc.id # YENİ VPC'ye bağla
}

# Cloud SQL verilen IP aralığını kullanabilmesi için VPC peering bağlantısı oluşturma
resource "google_service_networking_connection" "private_vpc_connection" {
  network                 = google_compute_network.main_vpc.id # YENİ VPC'ye bağla
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_ip_range.name]
  depends_on              = [google_project_service.networking_api, google_compute_network.main_vpc]
}

# Cloud Run için "güvenli tünel" (VPC Connector)
resource "google_vpc_access_connector" "main_connector" {
  name   = "main-connector"
  region = local.region # Değişkeni kullan

  # Connector'ın hangi alt ağda yaşayacağını belirt
  subnet {
    name = google_compute_subnetwork.main_subnet.name
  }

  machine_type = "f1-micro"
  depends_on   = [google_project_service.vpc_api, google_compute_subnetwork.main_subnet]
}

# === 3. GÜVENLİ VERİTABANI (CLOUD SQL) ===

resource "random_id" "db_name_suffix" {
  byte_length = 4
}

# PostgreSQL Veritabanı Kaynağı
resource "google_sql_database_instance" "main_db" {
  name             = "main-db-${random_id.db_name_suffix.hex}"
  region           = local.region # KRİTİK DÜZELTME: Artık us-central1 değil
  database_version = "POSTGRES_15"

  settings {
    tier = "db-f1-micro"
    ip_configuration {
      ipv4_enabled    = false
      private_network = google_compute_network.main_vpc.id # YENİ VPC'ye bağla
    }
  }
  depends_on = [
    google_project_service.sql_api,
    google_service_networking_connection.private_vpc_connection
  ]
}

# === 4. UYGULAMA DEPOSU (ARTIFACT REGISTRY) ===

resource "google_artifact_registry_repository" "my_repo" {
  location      = local.region # Değişkeni kullan
  repository_id = "my-backend-repo"
  format        = "DOCKER"
  depends_on    = [google_project_service.artifact_api]
}

# === 5. KİMLİKLER VE GÜVENLİK (IAM) ===

# --- Kimlik 1: Backend API Servisi (Uygulamanın Kendisi) ---
resource "google_service_account" "backend_api_sa" {
  account_id   = "backend-api-sa"
  display_name = "Backend API Service Account"
}

# Backend API'sinin İZİNLERİ:
resource "google_project_iam_member" "sql_client" {
  project = local.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.backend_api_sa.email}"
}
resource "google_project_iam_member" "log_writer" {
  project = local.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.backend_api_sa.email}"
}
resource "google_project_iam_member" "secret_accessor" {
  project = local.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.backend_api_sa.email}"
}

# --- Kimlik 2: Cloud Build (CI/CD Pipeline'ı) ---
resource "google_service_account" "cloud_build_sa" {
  account_id   = "cloud-build-sa"
  display_name = "Cloud Build Service Account"
}

# Cloud Build'un İZİNLERİ:
resource "google_project_iam_member" "build_log_writer" {
  project = local.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.cloud_build_sa.email}"
}
resource "google_project_iam_member" "run_admin" {
  project = local.project_id
  role    = "roles/run.admin"
  member  = "serviceAccount:${google_service_account.cloud_build_sa.email}"
}
resource "google_project_iam_member" "artifact_writer" {
  project = local.project_id
  role    = "roles/artifactregistry.writer"
  member  = "serviceAccount:${google_service_account.cloud_build_sa.email}"
}
resource "google_project_iam_member" "sa_user" {
  project = local.project_id
  role    = "roles/iam.serviceAccountUser"
  member  = "serviceAccount:${google_service_account.cloud_build_sa.email}"
}

# === 6. CLOUD RUN SERVİSİ (BOŞ UYGULAMA) ===

resource "google_cloud_run_service" "backend_api" {
  name     = "backend-api"
  location = local.region # Değişkeni kullan

  template {
    spec {
      # 'containers' bloğu SİLİNDİ.
      # Terraform artık imajı yönetmiyor.
      service_account_name = google_service_account.backend_api_sa.email
    }
    metadata {
      annotations = {
        "run.googleapis.com/vpc-access-connector" : google_vpc_access_connector.main_connector.name
        "run.googleapis.com/vpc-access-egress" : "private-ranges-only"
      }
    }
  }
  depends_on = [
    google_project_service.run_api,
    google_service_account.backend_api_sa,
    google_vpc_access_connector.main_connector
  ]
}

# === 7. GÜVENLİ ŞİFRE (SECRET MANAGER) ===

resource "random_password" "db_password" {
  length  = 20
  special = true
}

resource "google_secret_manager_secret" "db_password_secret" {
  secret_id = "db_password"
  replication {
    auto {} # v5 syntax
  }
  depends_on = [google_project_service.secretmanager_api]
}

resource "google_secret_manager_secret_version" "db_password_version" {
  secret      = google_secret_manager_secret.db_password_secret.id
  secret_data = random_password.db_password.result
}

# === 8. VERİTABANI VE KULLANICI (CLOUD SQL) ===

resource "google_sql_database" "main_database" {
  name     = "products-db"
  instance = google_sql_database_instance.main_db.name
}

resource "google_sql_user" "app_user" {
  name     = "app-user"
  instance = google_sql_database_instance.main_db.name
  password = random_password.db_password.result
}

# === 9. (İzinler Modül 5'e taşındı) ===

# === 10. ÇIKTILAR (OUTPUTS) ===

output "cloud_sql_connection_name" {
  value       = google_sql_database_instance.main_db.connection_name
  description = "Cloud SQL instance'ının bağlantı adı."
}

output "db_password_secret_id" {
  value       = google_secret_manager_secret_version.db_password_version.name
  description = "Şifrenin tam Secret Manager ID'si (versiyon dahil)."
}

output "db_name" {
  value = google_sql_database.main_database.name
}

output "db_user" {
  value = google_sql_user.app_user.name
}

# === 11. EKSİK İZİN (IAM - PUBLIC ACCESS) ===
# Cloud Run servisimize (backend-api) 'allUsers' (herkesin)
# erişebilmesi (çağırabilmesi) için "Invoker" rolü veriyoruz.
# Bu, 403 Forbidden (Yasak) hatasını çözer.

resource "google_cloud_run_service_iam_member" "public_invoker" {
  location = google_cloud_run_service.backend_api.location
  project  = google_cloud_run_service.backend_api.project
  service  = google_cloud_run_service.backend_api.name

  role   = "roles/run.invoker"
  member = "allUsers" # 'allUsers' internetteki herkes demektir
}

output "backend_api_url" {
  value       = google_cloud_run_service.backend_api.status[0].url
  description = "Deploy edilen Cloud Run servisinin URL'si."
}
