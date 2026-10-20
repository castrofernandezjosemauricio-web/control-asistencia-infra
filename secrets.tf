resource "random_password" "db" {
  length  = 24
  special = false
}

resource "random_password" "django_secret" {
  length  = 50
  special = false
}

