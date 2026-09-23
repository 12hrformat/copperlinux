#ifndef COPPER_BUILTINS_H
#define COPPER_BUILTINS_H

/* implemented in main.c */
int b_help(int argc, char **argv);
int b_exit(int argc, char **argv);
int b_history(int argc, char **argv);

/* implemented in builtins.c */
int b_pwd(int argc, char **argv);
int b_cd(int argc, char **argv);
int b_ls(int argc, char **argv);
int b_cat(int argc, char **argv);
int b_echo(int argc, char **argv);
int b_clear(int argc, char **argv);
int b_whoami(int argc, char **argv);
int b_uname(int argc, char **argv);
int b_date(int argc, char **argv);
int b_mkdir(int argc, char **argv);
int b_rmdir(int argc, char **argv);
int b_touch(int argc, char **argv);
int b_rm(int argc, char **argv);
int b_cp(int argc, char **argv);
int b_mv(int argc, char **argv);
int b_type(int argc, char **argv);
int b_which(int argc, char **argv);
int b_env(int argc, char **argv);

struct builtin {
    const char *name;
    int (*fn)(int, char **);
    const char *desc;
};

const struct builtin *builtin_lookup(const char *name);

#endif /* COPPER_BUILTINS_H */