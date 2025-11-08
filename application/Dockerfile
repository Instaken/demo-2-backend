FROM golang:1.21-alpine AS builder
WORKDIR /app
COPY go.mod . 
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -o /backend-api ./main.go


FROM alpine:latest
COPY --from=builder /backend-api /backend-api
EXPOSE 8080
ENTRYPOINT [ "/backend-api" ]
