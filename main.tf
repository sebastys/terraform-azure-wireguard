# Configure the Azure Provider
provider "azurerm" {
  features {}
  subscription_id = "99229b25-a420-4fa6-ad71-2d301b63513b"
}

# Create a resource group
resource "azurerm_resource_group" "wg_rg" {
  name     = "wireguard-rg"
  location = var.location
}

# Create a virtual network
resource "azurerm_virtual_network" "wg_vnet" {
  name                = "wireguard-vnet"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.wg_rg.location
  resource_group_name = azurerm_resource_group.wg_rg.name
}

# Create a subnet
resource "azurerm_subnet" "wg_subnet" {
  name                 = "wireguard-subnet"
  resource_group_name  = azurerm_resource_group.wg_rg.name
  virtual_network_name = azurerm_virtual_network.wg_vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}
resource "azurerm_subnet_network_security_group_association" "wg_subnet_nsg_assoc" {
  subnet_id                 = azurerm_subnet.wg_subnet.id
  network_security_group_id = azurerm_network_security_group.wg_nsg.id
}

# Create a public IP address
resource "azurerm_public_ip" "wg_pip" {
  name                = "wireguard-pip"
  location            = azurerm_resource_group.wg_rg.location
  resource_group_name = azurerm_resource_group.wg_rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

# Create a network security group
resource "azurerm_network_security_group" "wg_nsg" {
  name                = "wireguard-nsg"
  location            = azurerm_resource_group.wg_rg.location
  resource_group_name = azurerm_resource_group.wg_rg.name

  security_rule {
    name                       = "Wireguard"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Udp"
    source_port_range          = "*"
    destination_port_range     = "51820"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }

}

# Create a network interface
resource "azurerm_network_interface" "wg_nic" {
  name                = "wireguard-nic"
  location            = azurerm_resource_group.wg_rg.location
  resource_group_name = azurerm_resource_group.wg_rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.wg_subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.wg_pip.id
  }
}

# Associate the network security group with the network interface
resource "azurerm_network_interface_security_group_association" "wg_nsg_assoc" {
  network_interface_id      = azurerm_network_interface.wg_nic.id
  network_security_group_id = azurerm_network_security_group.wg_nsg.id
}

# Create a virtual machine
resource "azurerm_linux_virtual_machine" "wg_vm" {
  name                  = "wireguard-vm"
  resource_group_name   = azurerm_resource_group.wg_rg.name
  location              = azurerm_resource_group.wg_rg.location
  size                  = var.vm_size
  admin_username        = var.admin_username
  network_interface_ids = [azurerm_network_interface.wg_nic.id]

  admin_ssh_key {
    username   = var.admin_username
    public_key = file("/home/sebastian/.ssh/id_ed25519.pub")
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-focal"
    sku       = "20_04-lts"
    version   = "latest"
  }
}

# Execute a script on the VM to install and configure WireGuard
resource "azurerm_virtual_machine_extension" "wg_script" {
  name                 = "wireguard-install-script"
  virtual_machine_id   = azurerm_linux_virtual_machine.wg_vm.id
  publisher            = "Microsoft.Azure.Extensions"
  type                 = "CustomScript"
  type_handler_version = "2.0"

  settings = <<SETTINGS
    {
        "script": "${base64encode(templatefile("wireguard.sh", {
  client_count     = var.client_count,
  admin_username   = var.admin_username,
  server_public_ip = azurerm_public_ip.wg_pip.ip_address
}))}"
    }
SETTINGS
}

# Download the client configuration files
# Corrected version
resource "null_resource" "download_configs" {
  # This ensures the resource runs again if the VM is recreated
  triggers = {
    vm_id = azurerm_linux_virtual_machine.wg_vm.id
  }

  # This ensures the provisioner waits for the networking and the script to finish
  depends_on = [
    azurerm_virtual_machine_extension.wg_script,
    azurerm_subnet_network_security_group_association.wg_subnet_nsg_assoc,
  ]

  provisioner "local-exec" {
    # The 'replace' function strips Windows-style line endings (\r\n)
    # and replaces them with Unix-style endings (\n) to prevent syntax errors.
    command = replace(<<-EOT
      for i in $(seq 1 ${var.client_count}); do
        CONF_FILE="wg0-client-$i.conf"
        echo "Attempting to download $CONF_FILE..."
        for j in $(seq 1 10); do
          scp -o StrictHostKeyChecking=no -o ConnectTimeout=10 ${var.admin_username}@${azurerm_public_ip.wg_pip.ip_address}:/home/${var.admin_username}/$CONF_FILE .
          if [ $? -eq 0 ]; then
            echo "$CONF_FILE downloaded successfully."
            break 
          else
            if [ $j -eq 10 ]; then
              echo "Failed to download $CONF_FILE after 10 attempts."
              exit 1
            fi
            echo "Attempt $j failed. Retrying in 15 seconds..."
            sleep 15
          fi
        done
      done
    EOT
    , "\r\n", "\n")

    # We are now properly handling failures within the script, so we can remove on_failure.
    # If the script exits with an error (exit 1), Terraform will stop.
  }
}

# Output the public IP of the WireGuard server
output "wireguard_public_ip" {
  value = azurerm_public_ip.wg_pip.ip_address
}