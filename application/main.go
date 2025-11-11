package main

import (
	"context"
	"database/sql"
	"fmt"
	"log"
	"net/http"
	"os"

	"cloud.google.com/go/secretmanager/apiv1"
	"cloud.google.com/go/secretmanager/apiv1/secretmanagerpb"
	_ "github.com/jackc/pgx/v5/stdlib" // Sadece sürücüyü import et
)

var db *sql.DB // Veritabanı bağlantısını global yapıyoruz

func main() {
	// Adım 1: Gerekli 5 değeri ortam değişkenlerinden oku
	dbUser := os.Getenv("DB_USER")
	dbName := os.Getenv("DB_NAME")
	dbHost := os.Getenv("DB_HOST") // "127.0.0.1"
	dbPort := os.Getenv("DB_PORT") // "5432"
	dbSecretID := os.Getenv("DB_SECRET_ID")

	if dbUser == "" || dbName == "" || dbHost == "" || dbPort == "" || dbSecretID == "" {
		log.Fatal("DB_USER, DB_NAME, DB_HOST, DB_PORT veya DB_SECRET_ID ortam değişkenleri ayarlanmamış!")
	}

	// Adım 2: Veritabanı şifresini Secret Manager'dan (Kasa) güvenle al
	dbPass, err := getSecret(dbSecretID)
	if err != nil {
		log.Fatalf("Secret Manager'dan şifre alınamadı: %v", err)
	}

	// Adım 3: Basit (Standart) Veritabanı Bağlantısı
	// Artık karmaşık bir tünele (Dialer) ihtiyacımız yok.
	// Proxy bizim için '127.0.0.1:5432' adresini dinliyor.
	dsn := fmt.Sprintf("user=%s password=%s database=%s host=%s port=%s",
		dbUser, dbPass, dbName, dbHost, dbPort)

	db, err = sql.Open("pgx", dsn) // Standart "pgx" sürücüsünü kullan
	if err != nil {
		log.Fatalf("Veritabanı bağlantısı (sql.Open) açılamadı: %v", err)
	}

	// Adım 4: HTTP sunucusunu başlat
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		// Bağlantıyı test etmek için veritabanına 'ping' at
		if err := db.Ping(); err != nil {
			http.Error(w, fmt.Sprintf("Veritabanına ping atılamadı (Proxy bağlantısı başarısız?): %v", err), http.StatusInternalServerError)
			return
		}
		// BAŞARILI!
		fmt.Fprintf(w, "TEBRİKLER! Demo 2.0 Tamamlandı!\nCloud Run, VPC Connector üzerinden Özel IP'li Cloud SQL'e başarıyla bağlandı!")
	})

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	log.Printf("backend-api (v3 - Proxy Yöntemi) ':%s' portunda dinlemeye başlıyor...", port)
	if err := http.ListenAndServe(":"+port, nil); err != nil {
		log.Fatal(err)
	}
}

// getSecret: Secret Manager API'sini çağırarak şifreyi alır.
// (Bu fonksiyonda değişiklik yok, zaten doğruydu)
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