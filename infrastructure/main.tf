# === 1. GEREKLİ API'LERI AKTİF ETME ===
# Terraform yapılandırma dosyasını oluşturma
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
  region  = "europa-west3"
}

locals {
  project_id = "ozan-gcp-demo"
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

# === 2. AĞ (VPC) AYARLAMALARI ===

# Varsayılan VPC ağını alma
data "google_compute_network" "default" {
  name       = "default"
  depends_on = [google_project_service.compute_api]
}

# Cloud SQL için özel IP alabilmesi için bir IP aralığı oluşturma
resource "google_compute_global_address" "private_ip_address" {
  name          = "private-ip-range-for-sql"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = data.google_compute_network.default.id
}

# Cloud SQL verilen IP aralığını kullanabilmesi için VPC peering bağlantısı oluşturma
resource "google_service_networking_connection" "private_vpc_connection" {
  network                 = data.google_compute_network.default.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_ip_address.name]

  # Bu bağlantının, networking API etkinleştirilmeden oluşturulmamasını sağla
  depends_on = [google_project_service.networking_api]
}

resource "google_vpc_access_connector" "main_connector" {
  name          = "main-connector"
  region        = "europe-west3"
  ip_cidr_range = "10.8.0.0/28"
  network       = data.google_compute_network.default.id

  machine_type = "f1-micro"
  depends_on   = [google_project_service.vpc_api]

}

# === 3. GÜVENLİ VERİTABANI (CLOUD SQL) ===

# Cloud SQL örneği oluşturma
resource "random_id" "db_name_suffix" {
  byte_length = 4
}

# PostgreSQL Veritabanı Kaynağı
resource "google_sql_database_instance" "main_db" {
  name             = "main-db-${random_id.db_name_suffix.hex}"
  region           = "us-central1"
  database_version = "POSTGRES_15"

  settings {
    # Maliyet tasarrufu için en küçük (ve paylaşımlı) makine
    tier = "db-f1-micro"

    # === EN ÖNEMLİ GÜVENLİK KISMI ===
    ip_configuration {
      ipv4_enabled    = false                                  # Public IP'yi (Genel IP) KAPAT
      private_network = data.google_compute_network.default.id # Sadece 'default' ağdan erişim izni ver
    }
  }

  # Bu veritabanı, SQL API'si ve özel ağ bağlantısı hazır olduktan SONRA çalışmalı
  depends_on = [
    google_project_service.sql_api,
    google_service_networking_connection.private_vpc_connection
  ]
}

# === 4. UYGULAMA DEPOSU (ARTIFACT REGISTRY) ===

# Docker imajlarını depolamak için Artifact Registry deposu oluşturma

resource "google_project_service" "artifact_api" {
  service            = "artifactregistry.googleapis.com"
  disable_on_destroy = false
}

resource "google_artifact_registry_repository" "my_repo" {
  location      = "europe-west3"
  repository_id = "my-backend-repo"
  format        = "DOCKER"

  depends_on = [google_project_service.artifact_api]
}

# === 5. KİMLİKLER VE GÜVENLİK (IAM) ===

# --- Kimlik 1: Backend API Servisi (Uygulamanın Kendisi) ---
# Bu kimlik, Cloud Run servisi çalışırken kullanılacak.
resource "google_service_account" "backend_api_sa" {
  account_id   = "backend-api-sa"
  display_name = "Backend API Service Account"
}

# Backend API'sinin İZİNLERİ:
# İzin 1: Cloud SQL'e bağlanabilsin.
resource "google_project_iam_member" "sql_client" {
  project = local.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.backend_api_sa.email}"
}

# İzin 2 (Opsiyonel ama iyi pratik): Log yazabilsin.
resource "google_project_iam_member" "log_writer" {
  project = local.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.backend_api_sa.email}"
}

resource "google_project_iam_member" "build_log_writer" {
  project = local.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.cloud_build_sa.email}"
}

# --- Kimlik 2: Cloud Build (CI/CD Pipeline'ı) ---
# Bu kimlik, kodumuzu deploy ederken (CI/CD sürecinde) kullanılacak.
resource "google_service_account" "cloud_build_sa" {
  account_id   = "cloud-build-sa"
  display_name = "Cloud Build Service Account"
}

# Cloud Build'un İZİNLERİ:
# İzin 1: Cloud Run servisine yeni versiyon deploy edebilsin.
resource "google_project_iam_member" "run_admin" {
  project = local.project_id
  role    = "roles/run.admin"
  member  = "serviceAccount:${google_service_account.cloud_build_sa.email}"
}

# İzin 2: Artifact Registry'ye Docker imajı yükleyebilsin.
resource "google_project_iam_member" "artifact_writer" {
  project = local.project_id
  role    = "roles/artifactregistry.writer"
  member  = "serviceAccount:${google_service_account.cloud_build_sa.email}"
}

# İzin 3 (En Önemlisi): Cloud Run servisine "backend_api_sa" kimliğini atayabilsin.
resource "google_project_iam_member" "sa_user" {
  project = local.project_id
  role    = "roles/iam.serviceAccountUser"
  # ÖNEMLİ: Bu rol, "cloud_build_sa"ya (pipeline) "backend_api_sa"yı (uygulama) 
  # kullanma izni verir.
  member = "serviceAccount:${google_service_account.cloud_build_sa.email}"
}

# === 6. CLOUD RUN SERVİSİ (BOŞ UYGULAMA) ===
# "backend-api" adında bir Cloud Run servisi oluşturuyoruz.
# Henüz içinde bir imaj yok, sadece "yerini" hazırlıyoruz.

resource "google_cloud_run_service" "backend_api" {
  name     = "backend-api"
  location = "europe-west3"

  # Başlangıçta boş bir "hello world" imajı ile başlatalım
  template {
    spec {
      containers {
        image = "us-docker.pkg.dev/cloudrun/container/hello"
      }

      # === MODÜL 1 VE 2'Yİ BİRBİRİNE BAĞLAYAN YER ===

      # 1. GÜVENLİK (IAM): "Bu servis, 'backend_api_sa' kimliğini kullansın"
      service_account_name = google_service_account.backend_api_sa.email

    }

    metadata {
      annotations = {
        # 2. AĞ (VPC): "Bu servis, 'main_connector' tünelini kullansın"
        "run.googleapis.com/vpc-access-connector" : google_vpc_access_connector.main_connector.name
        # 3. AĞ (VPC): "Tüm giden trafik SADECE özel ağdan (VPC) geçsin, internete çıkmasın"
        "run.googleapis.com/vpc-access-egress" : "private-ranges-only"
      }
    }
  }

  # Bu servis, Cloud Run API'si aktif olduktan ve
  # kullanacağı kimlik ile tünel hazır olduktan sonra çalışmalı
  depends_on = [
    google_project_service.run_api,
    google_service_account.backend_api_sa,
    google_vpc_access_connector.main_connector
  ]
}
