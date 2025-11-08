package main

import (
	"fmt"
	"log"
	"net/http"
	"os"
)

func main() {
	// Cloud Run, hangi portu dinleyeceğini 'PORT' ortam değişkeniyle söyler.
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		// Şimdilik sadece basit bir "Merhaba" mesajı.
		// Modül 4'te buraya veritabanı bağlantısını ekleyeceğiz.
		fmt.Fprintf(w, "Merhaba! Demo 2.0 CI/CD Pipeline çalıştı!")
	})

	log.Printf("backend-api ':%s' portunda dinlemeye başlıyor...", port)
	if err := http.ListenAndServe(":"+port, nil); err != nil {
		log.Fatal(err)
	}
}