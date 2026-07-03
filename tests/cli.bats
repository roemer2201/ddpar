#!/usr/bin/env bats
#
# Verhalten der Kommandozeile (ohne echte Klon-/Backup-Operationen).

load helpers

# --- ddpar.sh ---

@test "ddpar.sh -h zeigt die Hilfe und endet mit Code 0" {
  vrun "$REPO_ROOT/ddpar.sh" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"Verwendung"* ]]
}

@test "ddpar.sh ohne Parameter scheitert mit Code 1" {
  vrun "$REPO_ROOT/ddpar.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Fehlende Parameter"* ]]
}

@test "ddpar.sh nur mit -i (ohne -o) scheitert mit Code 1" {
  vrun "$REPO_ROOT/ddpar.sh" -i /etc/hostname
  [ "$status" -eq 1 ]
  [[ "$output" == *"Fehlende Parameter"* ]]
}

# --- ddpar-restore.sh ---

@test "ddpar-restore.sh -h zeigt die Hilfe" {
  vrun "$REPO_ROOT/ddpar-restore.sh" -h
  [[ "$output" == *"Verwendung"* ]]
}

@test "ddpar-restore.sh kennt das -y-Flag" {
  vrun "$REPO_ROOT/ddpar-restore.sh" -h
  [[ "$output" == *"-y"* ]]
}

# --- ddpar-check.sh ---

@test "ddpar-check.sh -h zeigt die Hilfe und endet mit Code 0" {
  vrun "$REPO_ROOT/ddpar-check.sh" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"Verwendung"* ]]
}

@test "ddpar-check.sh ohne Parameter scheitert mit Code 1" {
  vrun "$REPO_ROOT/ddpar-check.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"None of the three variables is set"* ]]
}

@test "ddpar-check.sh mit nur einem Vergleichspartner scheitert mit Code 1" {
  vrun "$REPO_ROOT/ddpar-check.sh" -s /etc/hostname
  [ "$status" -eq 1 ]
  [[ "$output" == *"Only one of the three variables is set"* ]]
}
