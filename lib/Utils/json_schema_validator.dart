import 'dart:convert';

/// Very small JSON Schema (Draft-07-ish subset) validator for our tool args.
/// Supported keywords:
/// - type: object,string,number,integer,boolean,array
/// - required: [..]
/// - properties: { key: { type, enum, minimum, maximum, minLength, maxLength } }
/// - additionalProperties: bool (when false, disallow unknown keys)
/// - items (array of simple types)
/// - enum: [..]
/// This is intentionally minimal; extend as needed.
class JsonSchemaValidator {
  List<String> validate(Map<String, dynamic> schema, dynamic data, {String path = ''}) {
    final errors = <String>[];
    _validate(schema, data, path, errors);
    return errors;
  }

  void _validate(Map<String, dynamic> schema, dynamic data, String path, List<String> errors) {
    final type = schema['type'];
    if (type != null) {
      if (!_checkType(type, data)) {
        errors.add('${_p(path)}: expected type $type, got ${_typeOf(data)}');
        return; // don't cascade further if top-level type mismatches
      }
    }

    if (type == 'object' && data is Map) {
      final props = (schema['properties'] as Map?)?.cast<String, dynamic>() ?? const {};
      final required = (schema['required'] as List?)?.cast<String>() ?? const <String>[];
      final additional = schema['additionalProperties'];

      // required
      for (final req in required) {
        if (!data.containsKey(req)) {
          errors.add('${_p(path)}: missing required property "$req"');
        }
      }

      // properties
      for (final entry in props.entries) {
        final key = entry.key;
        final subschema = (entry.value as Map).cast<String, dynamic>();
        if (data.containsKey(key)) {
          _validate(subschema, data[key], _child(path, key), errors);
        }
      }

      // additionalProperties = false
      if (additional == false) {
        final allowedKeys = props.keys.toSet();
        for (final k in data.keys) {
          if (!allowedKeys.contains(k)) {
            errors.add('${_p(path)}: unexpected property "$k"');
          }
        }
      }
    }

    if (type == 'array' && data is List) {
      final items = schema['items'];
      if (items is Map<String, dynamic>) {
        for (var i = 0; i < data.length; i++) {
          _validate(items, data[i], _child(path, '[$i]'), errors);
        }
      }
      final minItems = schema['minItems'];
      if (minItems is int && data.length < minItems) {
        errors.add('${_p(path)}: array length ${data.length} < minItems $minItems');
      }
      final maxItems = schema['maxItems'];
      if (maxItems is int && data.length > maxItems) {
        errors.add('${_p(path)}: array length ${data.length} > maxItems $maxItems');
      }
    }

    // Scalars constraints
    if (data is String) {
      final minLength = schema['minLength'];
      if (minLength is int && data.length < minLength) {
        errors.add('${_p(path)}: string length ${data.length} < minLength $minLength');
      }
      final maxLength = schema['maxLength'];
      if (maxLength is int && data.length > maxLength) {
        errors.add('${_p(path)}: string length ${data.length} > maxLength $maxLength');
      }
      final enums = schema['enum'];
      if (enums is List && !enums.contains(data)) {
        errors.add('${_p(path)}: value "$data" not in enum ${jsonEncode(enums)}');
      }
    } else if (data is num) {
      final minimum = schema['minimum'];
      if (minimum is num && data < minimum) {
        errors.add('${_p(path)}: number $data < minimum $minimum');
      }
      final maximum = schema['maximum'];
      if (maximum is num && data > maximum) {
        errors.add('${_p(path)}: number $data > maximum $maximum');
      }
      final enums = schema['enum'];
      if (enums is List && !enums.contains(data)) {
        errors.add('${_p(path)}: value $data not in enum ${jsonEncode(enums)}');
      }
    } else if (data is bool) {
      final enums = schema['enum'];
      if (enums is List && !enums.contains(data)) {
        errors.add('${_p(path)}: value $data not in enum ${jsonEncode(enums)}');
      }
    }
  }

  bool _checkType(dynamic type, dynamic data) {
    if (type is List) {
      return type.any((t) => _checkType(t, data));
    }
    switch (type) {
      case 'object':
        return data is Map;
      case 'array':
        return data is List;
      case 'string':
        return data is String;
      case 'number':
        return data is num; // includes int & double
      case 'integer':
        return data is int;
      case 'boolean':
        return data is bool;
      case null:
        return true;
      default:
        return true; // unknown type -> ignore
    }
  }

  String _typeOf(dynamic data) {
    if (data == null) return 'null';
    if (data is Map) return 'object';
    if (data is List) return 'array';
    if (data is String) return 'string';
    if (data is int) return 'integer';
    if (data is num) return 'number';
    if (data is bool) return 'boolean';
    return data.runtimeType.toString();
  }

  String _p(String path) => path == '\u0018' ? '' : path;
  String _child(String path, String key) {
    if (path == '\u0018') return key;
    if (key.startsWith('[')) return '$path$key';
    return '$path.$key';
  }
}
