#ifndef HAD_CONFIG_H
#define HAD_CONFIG_H
#ifndef _HAD_ZIPCONF_H
#include "zipconf.h"
#endif
/* BEGIN DEFINES */
/* #undef HAVE___PROGNAME */
/* #undef HAVE__CLOSE */
/* #undef HAVE__DUP */
/* #undef HAVE__FDOPEN */
/* #undef HAVE__FILENO */
/* #undef HAVE__SETMODE */
/* #undef HAVE__SNPRINTF */
/* #undef HAVE__STRDUP */
/* #undef HAVE__STRICMP */
/* #undef HAVE__STRTOI64 */
/* #undef HAVE__STRTOUI64 */
/* #undef HAVE__UMASK */
/* #undef HAVE__UNLINK */
#define HAVE_ARC4RANDOM
#define HAVE_CLONEFILE
#define HAVE_COMMONCRYPTO
#define HAVE_CRYPTO
/* #undef HAVE_FICLONERANGE */
#define HAVE_FILENO
#define HAVE_FCHMOD
#define HAVE_FSEEKO
#define HAVE_FTELLO
#define HAVE_GETPROGNAME
/* #undef HAVE_GNUTLS */
#define HAVE_LIBBZ2
#define HAVE_LIBLZMA
#define HAVE_LIBZSTD
#define HAVE_LOCALTIME_R
/* #undef HAVE_MBEDTLS */
/* #undef HAVE_MKSTEMP */
#define HAVE_NULLABLE
/* #undef HAVE_OPENSSL */
#define HAVE_SETMODE
#define HAVE_SNPRINTF
#define HAVE_STRCASECMP
#define HAVE_STRDUP
/* #undef HAVE_STRICMP */
#define HAVE_STRTOLL
#define HAVE_STRTOULL
/* #undef HAVE_STRUCT_TM_TM_ZONE */
#define HAVE_STDBOOL_H
#define HAVE_STRINGS_H
#define HAVE_UNISTD_H
/* #undef HAVE_WINDOWS_CRYPTO */
#define SIZEOF_OFF_T 8
#define SIZEOF_SIZE_T 8
/* #undef HAVE_DIRENT_H */
#define HAVE_FTS_H
/* #undef HAVE_NDIR_H */
/* #undef HAVE_SYS_DIR_H */
/* #undef HAVE_SYS_NDIR_H */
/* #undef WORDS_BIGENDIAN */
#define HAVE_SHARED
/* END DEFINES */
#define PACKAGE "libzip"
#define VERSION "1.9.2"

#endif /* HAD_CONFIG_H */
