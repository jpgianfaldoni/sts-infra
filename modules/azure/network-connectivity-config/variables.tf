variable "name" {
  type = string
}

variable "region" {
  description = "Region of the workspace; an NCC can only be attached to workspaces in its region."
  type        = string
}
