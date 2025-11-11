package main

import (
	"context"
	"database/sql"
	"fmt"
	"log"
	"net/http"
	"os"

	"cloud.google.com/go/cloudsqlconn"
	"cloud.google.com/go/secretmanager/apiv1"
	"cloud.google.com/go/secretmanager/apiv1/secretmanagerpb"

	// PGX v5'in 'database/sql' sürücüsünü (stdlib) import ediyoruz
	"github.com/jackc/pgx/v5/stdlib"
)

var db *sql.DB // Veritabanı bağlantısını global yapıyoruz

func main() {
	// Adım 1: Gerekli 4 değeri ortam değişkenlerinden (Environment Variables) oku
	dbUser := os.Getenv("DB_USER")
	dbName := os.Getenv("DB_NAME")
	dbSecretID := os.Getenv("DB_SECRET_ID")
	dbConnectionName := os.Getenv("DB_CONN_NAME")

	if dbUser == "" || dbName == "" || dbSecretID == "" || dbConnectionName == "" {
		log.Fatalf("DB_USER, DB_NAME, DB_SECRET_ID, veya DB_CONN_NAME ortam değişkenleri ayarlanmamış!")
	}

	// Adım 2: Veritabanı şifresini Secret Manager'dan (Kasa) güvenle al
	dbPass, err := getSecret(dbSecretID)
	if err != nil {
		log.Fatalf("Secret Manager'dan şifre alınamadı: %v", err)
	}

	// Adım 3: Cloud SQL'e özel (private) bağlantıyı kur
	// (Bu, 'connectWithConnector' fonksiyonunun DÜZELTİLMİŞ halidir)
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

// === BOZUK FONKSİYONUN DÜZELTİLMİŞ HALİ ===
func connectWithConnector(user, pass, db, connName string) (*sql.DB, error) {
	ctx := context.Background()
	// 1. Dialer (Tünel) oluştur
	d, err := cloudsqlconn.NewDialer(ctx)
	if err != nil {
		return nil, err
	}
	
	// 2. DSN (Bağlantı Bilgisi) hazırla
	// 'stdlib' sürücüsünün özel 'cloudsql' formatını kullanıyoruz
	dsn := fmt.Sprintf("user=%s password=%s database=%s host=%s", user, pass, db, connName)
	
	// 3. 'pgx/v5/stdlib' sürücüsünü, özel Dialer'ımızı (tünel) kullanacak şekilde
	// 'database/sql' kütüphanesine KAYDET (Register)
	// (RegisterDriver yerine bu kullanılır)
	sql.Register("cloudsql-postgres", cloudsqlconn.Driver(d, cloudsqlconn.IAMAuthN))

	// 4. Bağlantıyı aç
	// (Burada "cloudsql-postgres" ismini kullanıyoruz, çünkü az önce kaydettik)
	return sql.Open("cloudsql-postgres", dsn)
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