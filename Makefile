build:
	docker compose build

up:
	docker compose up -d

down:
	docker compose down --remove-orphans

shell:
	docker compose exec web bash

console:
	docker compose exec web rails console
