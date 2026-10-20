variable "project_name" {
  description = "Prefijo distinto del despliegue anterior."
  type        = string
  default     = "asistencia-lab3-v2"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,30}$", var.project_name))
    error_message = "Usar entre 3 y 31 letras minusculas, numeros o guiones."
  }
}
variable "aws_region" {
  type    = string
  default = "us-east-1"
}
variable "instance_type" {
  type    = string
  default = "t3.small"
}
variable "ssh_cidr" {
  description = "IPv4 publica autorizada para EC2 Instance Connect o SSH."
  type        = string
  default     = "18.206.107.24/29"
}
variable "ami_id" {
  description = "AMI Ubuntu 24.04 amd64 fijada para evitar reemplazos al cambiar la mas reciente."
  type        = string
  default     = "ami-02a9cdd4e98bc3c78"
}
