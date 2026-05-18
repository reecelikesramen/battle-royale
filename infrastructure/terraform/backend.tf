terraform {
  backend "gcs" {
    bucket = "erudite-cycle-480104-tfstate"
    prefix = "terraform/state"
  }
}
