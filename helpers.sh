name_to_id() {
  case $1 in
    gateway) echo 0;;
    control[0-2]) echo $((1 + ${1#control}));;
    worker[0-2]) echo $((4 + ${1#worker}));;
    *) echo "Bad machine name: $1" >&2; return 1
  esac
}

id_to_name() {
  id=$1
  if [[ ! $id =~ ^-?[0-9]+$ ]]; then echo "bad machine ID: $id" >&2; return 1
  elif [[ $id -eq 0 ]]; then echo gateway
  elif [[ $id -le 3 ]]; then echo control$(($id - 1))
  elif [[ $id -le 6 ]]; then echo worker$(($id - 4))
  else echo "bad machine ID: $id" >&2; return 1
  fi
}

