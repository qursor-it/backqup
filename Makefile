test:
	GO_ENV=test go test ./...
test\:all:
	@sh tests/test.sh
perform:
	@go run main.go -- perform -m demo -c ./gobackup_test.yml
run:
	GO_ENV=dev go run main.go -- run --config ./gobackup_test.yml
start:
	GO_ENV=dev go run main.go -- start --config ./gobackup_test.yml
build:
	go build -o dist/gobackup
