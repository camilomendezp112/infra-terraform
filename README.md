## Arquitectura
El flujo de una petición típica:
**Frontend** → **Cognito** (Genera JWT con `tenant_id`) → **API Gateway** (Valida JWT) → **Lambda** (Ejecuta en Python 3.11 aislando lógicamente por `tenant_id`) → **DynamoDB** (Almacena en single table).

### Prevención de Hot Partitions
Se ha diseñado el modelo de DynamoDB usando `PK = TENANT#<tenant_id>` y `SK = ASSET#<asset_id>`. Para escalar a miles o millones de activos, DynamoDB soporta esta estructura inherentemente, pero de ser necesario para un tráfico inmenso concentrado en un tenant específico, se recomienda agregar "Sharding" en la PK:
`PK = TENANT#<tenant_id>#<shard_id>`

## 💻 Requisitos
- [Terraform](https://developer.hashicorp.com/terraform/downloads) instalado
- Cuenta de AWS y CLI configurados (`aws configure`)
- Python 3.11 para revisar las lambdas (opcional para ejecutar simulaciones)

## ómo Desplegar

1. **Inicializar Terraform**
   Descargará los providers (AWS).
   ```bash
   terraform init
   ```


2. **Aplicar los Cambios**
   Despliega Commit Changes


 3. **Visualizar cambios**
    Se visualiza Githbub Actions para ver los cambios exitosamente
