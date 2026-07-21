open Pp_kernel

type registration = {
  name : string;
  entry : Session.domain_entry;
}

val decode_domain :
  force:(Core_model.value -> Core_model.value) ->
  Core_model.value ->
  (registration, string) result

val decode_probe :
  force:(Core_model.value -> Core_model.value) ->
  Core_model.value ->
  Core_model.value ->
  Core_model.value ->
  (registration, string) result
