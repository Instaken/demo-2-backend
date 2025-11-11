package main

import (
	"context"
	"database/sql"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"

	"cloud.google.com/go/cloudsqlconn"
	"cloud.google.com/go/secretmanager/apiv1"
	"cloud.google.com/go/secretmanager/apiv1/secretmanagerpb"
	"github.com/jackc/pgx/v5/stdlib"
)

var db *sql.DB // Veritabanı bağlantısını global yapıyoruz

func main() {
	// Adım 1: Gerekli 4 değeri ortam değişkenlerinden (Environment Variables) oku
	// (Bu değişkenleri bir sonraki adımda 'cloudbuild.yaml' ile ayarlayacağız)
	dbUser := os.Getenv("DB_USER")                 // 'app-user'
	dbName := os.Getenv("DB_NAME")                 // 'products-db'
	dbSecretID := os.Getenv("DB_SECRET_ID")        // 'projects/...'
	dbConnectionName := os.Getenv("DB_CONN_NAME")  // 'ozan-gcp-demo:europa-west3:...'

	if dbUser == "" || dbName == "" || dbSecretID == "" || dbConnectionName == "" {
		log.Fatal("DB_USER, DB_NAME, DB_SECRET_ID, veya DB_CONN_NAME ortam değişkenleri ayarlanmamış!")
	}

	// Adım 2: Veritabanı şifresini Secret Manager'dan (Kasa) güvenle al
	dbPass, err := getSecret(dbSecretID)
	if err != nil {
		log.Fatalf("Secret Manager'dan şifre alınamadı: %v", err)
	}

	// Adım 3: Cloud SQL'e özel (private) bağlantıyı kur
	db, err = connectWithConnector(dbUser, dbPass, dbName, dbConnectionName)
	if err != nil {
		log.Fatalf("Cloud SQL'e bağlanılamadı: %v", err)
	}

	// Adım 4: HTTP sunucusunu başlat
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		// Bağlantıyı test etmek için veritabanına 'ping' at
		if err := db.Ping(); err != nil {
			http.Error(w, fmt.Sprintf("Veritabanına ping atılamadı: %v", err), http.StatusInternalServerError)
			return
		}
		// BAŞARILI!
		fmt.Fprintf(w, "TEBRİKLER! Demo 2.0 Tamamlandı!\nCloud Run, VPC Connector üzerinden Özel IP'li Cloud SQL'e başarıyla bağlandı!")
	})

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	log.Printf("backend-api (v2 - DB Bağlantılı) ':%s' portunda dinlemeye başlıyor...", port)
	if err := http.ListenAndServe(":"+port, nil); err != nil {
		log.Fatal(err)
	}
}

// connectWithConnector: Google'ın sağladığı 'Cloud SQL Connector'ı kullanarak
// VPC tüneli üzerinden güvenli bir bağlantı açar.
func connectWithConnector(user, pass, db, connName string) (*sql.DB, error) {
	d, err := cloudsqlconn.NewDialer(context.Background())
	if err != nil {
		return nil, err
	}
	var opts []cloudsqlconn.DialOption
	config, err := stdlib.RegisterDriver("cloudsql-postgres", cloudsqlconn.WithDialer(d), cloudsqlconn.WithIAMAuthN())
	if err != nil {
		return nil, err
	}

	dsn := fmt.Sprintf("user=%s password=%s database=%s host=%s", user, pass, db, connName)
	return sql.Open("cloudsql-postgres", dsn)
}

// getSecret: Secret Manager API'sini çağırarak şifreyi alır.
func getSecret(secretID string) (string, error) {
	ctx := context.Background()
	client, err := secretmanager.NewClient(ctx)
	if err != nil {
		return "", fmt.Errorf("secretmanager istemcisi oluşturulamadı: %w", err)
	}
	defer client.Close()

	req := &secretmanagerpb.AccessSecretVersionRequest{
		Name: secretID,
	}
	result, err := client.AccessSecretVersion(ctx, req)
	if err != nil {
		return "", fmt.Errorf("secret versiyonuna erişilemedi: %w", err)
	}
	return string(result.Payload.Data), nil
}