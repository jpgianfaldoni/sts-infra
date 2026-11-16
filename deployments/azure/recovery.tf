# Only ./infra recover-plan supplies these IDs, after inspecting this lab's
# vault metadata. Ordinary plans have no imports. Terraform reads and adopts
# each existing secret during the saved plan rather than failing at create.
import {
  for_each = var.recovery_secret_imports

  to = module.key_vault[0].azurerm_key_vault_secret.this[each.key]
  id = each.value
}
