module github.com/ozan/demo-2-backend

go 1.21

require (
	cloud.google.com/go/cloudsqlconn v1.4.5
	cloud.google.com/go/secretmanager v1.12.0
	github.com/jackc/pgx/v5 v5.5.0
	golang.org/x/oauth2 v0.13.0 // Gerekli alt bağımlılık
)