.PHONY: up test check integration auth-test down
up:
	docker compose up -d --build --wait
test:
	go test ./...
check:
	go vet ./...
integration:
	python3 -m unittest discover -s tests/integration -v
auth-test:
	docker compose --profile test run --rm auth-tests
down:
	docker compose down
