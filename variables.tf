variable "location" {
  description = "The Azure region to deploy the resources in."
  default     = "East US"
}

variable "vm_size" {
  description = "The size of the virtual machine."
  default     = "Standard_B1s" # Changed to a more cost-effective default
}

variable "admin_username" {
  description = "The admin username for the virtual machine."
  default     = "azureuser"
}

variable "client_count" {
  description = "The number of WireGuard client configuration files to generate."
  default     = 5
}