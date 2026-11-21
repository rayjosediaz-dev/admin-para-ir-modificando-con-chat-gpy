# Panther Admin — pantalla completa + icono pantera

Proyecto SwiftUI para iPhone. Cambios:
- ScrollView ocupa toda la altura disponible, alineado arriba (corrige el cuadro centrado y los espacios negros grandes).
- Encabezado pantera y personaje en el primer bloque, sin márgenes superiores innecesarios.
- Barra inferior fija; el contenido se desplaza sin quedar oculto.
- Icono AppIcon de pantera azul basado en la vista previa elegida.
- No se cambió la API ni la lógica de administración de keys/patches.

## GitHub
Sube el contenido descomprimido a tu repositorio, reemplaza archivos anteriores y ejecuta Actions. Descarga el artefacto `Panther-Keygarden-Admin-unsigned`.

**Nota:** IPA sin firmar; requiere firma válida. La disposición exacta depende de pantalla, Dynamic Type y safe areas. No se ha compilado en Xcode aquí.


## Corrección de pantalla completa
Se añadió `INFOPLIST_KEY_UILaunchScreen_Generation: YES` para evitar el modo de compatibilidad con bandas negras en iPhone, y `UIRequiresFullScreen`. La raíz SwiftUI utiliza el tamaño completo del contenedor, mantiene el scroll y la barra inferior.

Para ver el cambio, compila una IPA nueva y reemplaza la instalación anterior. El resultado visual final requiere comprobación en un iPhone físico.

## Gestión de revendedores
Pestaña Revendedores: crear cuentas, recargar/descontar créditos, activar/suspender cuentas y establecer precios de 1, 5 y 30 días. Requiere el servidor PantherServidor_Reseller_Integrado desplegado y token ADMIN válido.
