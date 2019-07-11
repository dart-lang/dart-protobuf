// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

part of protoc;

/// Generates the Dart enum corresponding to a oneof declaration.
///
/// The enum is used to represent the state of a oneof when using the
/// corresponding which-method.
class OneofEnumGenerator {
  static void generate(
      IndentingWriter out, String classname, List<ProtobufField> fields) {
    out.addBlock('enum ${classname} {', '}\n', () {
      for (ProtobufField field in fields) {
        final name = oneofEnumMemberName(field.memberNames.fieldName);
        out.println('$name, ');
      }
      out.println('notSet');
    });
  }
}

class MessageGenerator extends ProtobufContainer {
  /// Returns the mixin for this message, or null if none.
  ///
  /// First searches [declaredMixins], then internal mixins declared by
  /// [findMixin].
  static PbMixin _getMixin(DescriptorProto desc, FileDescriptorProto file,
      Map<String, PbMixin> declaredMixins, PbMixin defaultMixin) {
    if (!desc.hasOptions() || !desc.options.hasExtension(Dart_options.mixin)) {
      return defaultMixin;
    }

    String name = desc.options.getExtension(Dart_options.mixin);
    if (name.isEmpty) return null; // don't use any mixins (override default)
    var mixin = declaredMixins[name] ?? findMixin(name);
    if (mixin == null) {
      throw '${desc.name} in ${file.name}: mixin "$name" not found';
    }
    return mixin;
  }

  /// The name of the Dart class to generate.
  final String classname;

  /// The fully-qualified name of the message (without any leading '.').
  final String fullName;

  /// The part of the fully qualified name that comes after the package prefix.
  ///
  /// For nested messages this will include the names of the parents.
  ///
  /// For example:
  /// ```
  /// package foo;
  ///
  /// message Container {
  ///   message Nested {
  ///     int32 int32_value = 1;
  ///   }
  /// }
  /// ```
  /// The nested message will have a `fullName` of 'foo.Container.Nested', and a
  /// `messageName` of 'Container.Nested'.
  String get messageName =>
      fullName.substring(package.isEmpty ? 0 : package.length + 1);

  final PbMixin mixin;

  final ProtobufContainer _parent;
  final DescriptorProto _descriptor;
  final List<EnumGenerator> _enumGenerators = <EnumGenerator>[];
  final List<MessageGenerator> _messageGenerators = <MessageGenerator>[];
  final List<ExtensionGenerator> _extensionGenerators = <ExtensionGenerator>[];
  // Stores the list of fields belonging to each oneof declaration identified
  // by the index in the containing types's oneof_decl list.
  final List<List<ProtobufField>> _oneofFields;
  List<OneofNames> _oneofNames;

  List<int> _fieldPath;
  final List<int> _fieldPathSegment;

  /// See [[ProtobufContainer]
  List<int> get fieldPath =>
      _fieldPath ??= List.from(_parent.fieldPath)..addAll(_fieldPathSegment);

  // populated by resolve()
  List<ProtobufField> _fieldList;

  Set<String> _usedTopLevelNames;

  MessageGenerator._(
      DescriptorProto descriptor,
      ProtobufContainer parent,
      Map<String, PbMixin> declaredMixins,
      PbMixin defaultMixin,
      this._usedTopLevelNames,
      int repeatedFieldIndex,
      int fieldIdTag)
      : _descriptor = descriptor,
        _parent = parent,
        _fieldPathSegment = [fieldIdTag, repeatedFieldIndex],
        classname = messageOrEnumClassName(descriptor.name, _usedTopLevelNames,
            parent: parent?.classname ?? ''),
        assert(parent != null),
        fullName = parent.fullName == ''
            ? descriptor.name
            : '${parent.fullName}.${descriptor.name}',
        mixin = _getMixin(descriptor, parent.fileGen.descriptor, declaredMixins,
            defaultMixin),
        _oneofFields =
            List.generate(descriptor.oneofDecl.length, (int index) => []) {
    for (var i = 0; i < _descriptor.enumType.length; i++) {
      EnumDescriptorProto e = _descriptor.enumType[i];
      _enumGenerators.add(EnumGenerator.nested(e, this, _usedTopLevelNames, i));
    }

    for (var i = 0; i < _descriptor.nestedType.length; i++) {
      DescriptorProto n = _descriptor.nestedType[i];
      _messageGenerators.add(MessageGenerator.nested(
          n, this, declaredMixins, defaultMixin, _usedTopLevelNames, i));
    }

    // Extensions within messages won't create top-level classes and don't need
    // to check against / be added to top-level reserved names.
    final usedExtensionNames = Set<String>()..addAll(forbiddenExtensionNames);
    for (var i = 0; i < _descriptor.extension.length; i++) {
      FieldDescriptorProto x = _descriptor.extension[i];
      _extensionGenerators
          .add(ExtensionGenerator.nested(x, this, usedExtensionNames, i));
    }
  }

  static const _topLevelMessageTag = 4;
  static const _nestedMessageTag = 3;
  static const _messageFieldTag = 2;

  MessageGenerator.topLevel(
      DescriptorProto descriptor,
      ProtobufContainer parent,
      Map<String, PbMixin> declaredMixins,
      PbMixin defaultMixin,
      Set<String> usedNames,
      int repeatedFieldIndex)
      : this._(descriptor, parent, declaredMixins, defaultMixin, usedNames,
            repeatedFieldIndex, _topLevelMessageTag);

  MessageGenerator.nested(
      DescriptorProto descriptor,
      ProtobufContainer parent,
      Map<String, PbMixin> declaredMixins,
      PbMixin defaultMixin,
      Set<String> usedNames,
      int repeatedFieldIndex)
      : this._(descriptor, parent, declaredMixins, defaultMixin, usedNames,
            repeatedFieldIndex, _nestedMessageTag);

  String get package => _parent.package;

  /// The generator of the .pb.dart file that will declare this type.
  FileGenerator get fileGen => _parent.fileGen;

  /// Throws an exception if [resolve] hasn't been called yet.
  void checkResolved() {
    if (_fieldList == null) {
      throw StateError("message not resolved: ${fullName}");
    }
  }

  /// Returns a const expression that evaluates to the JSON for this message.
  /// [usage] represents the .pb.dart file where the expression will be used.
  String getJsonConstant(FileGenerator usage) {
    var name = "$classname\$json";
    if (usage.protoFileUri == fileGen.protoFileUri) {
      return name;
    }
    return "$fileImportPrefix.$name";
  }

  /// Adds all mixins used in this message and any submessages.
  void addMixinsTo(Set<PbMixin> output) {
    if (mixin != null) {
      output.addAll(mixin.findMixinsToApply());
    }
    for (var m in _messageGenerators) {
      m.addMixinsTo(output);
    }
  }

  // Registers message and enum types that can be used elsewhere.
  void register(GenerationContext ctx) {
    ctx.registerFieldType(this);
    for (var m in _messageGenerators) {
      m.register(ctx);
    }
    for (var e in _enumGenerators) {
      e.register(ctx);
    }
  }

  // Creates fields and resolves extension targets.
  void resolve(GenerationContext ctx) {
    if (_fieldList != null) throw StateError("message already resolved");

    var reserved = mixin?.findReservedNames() ?? const <String>[];
    MemberNames members = messageMemberNames(
        _descriptor, classname, _usedTopLevelNames,
        reserved: reserved);

    _fieldList = <ProtobufField>[];
    for (FieldNames names in members.fieldNames) {
      ProtobufField field = ProtobufField.message(names, this, ctx);
      if (field.descriptor.hasOneofIndex()) {
        _oneofFields[field.descriptor.oneofIndex].add(field);
      }
      _fieldList.add(field);
    }
    _oneofNames = members.oneofNames;

    for (var m in _messageGenerators) {
      m.resolve(ctx);
    }
    for (var x in _extensionGenerators) {
      x.resolve(ctx);
    }
  }

  bool get needsFixnumImport {
    if (_fieldList == null) throw StateError("message not resolved");
    for (var field in _fieldList) {
      if (field.needsFixnumImport) return true;
    }
    for (var m in _messageGenerators) {
      if (m.needsFixnumImport) return true;
    }
    for (var x in _extensionGenerators) {
      if (x.needsFixnumImport) return true;
    }
    return false;
  }

  /// Adds dependencies of [generate] to [imports].
  ///
  /// For each .pb.dart file that the generated code needs to import,
  /// add its generator.
  void addImportsTo(
      Set<FileGenerator> imports, Set<FileGenerator> enumImports) {
    if (_fieldList == null) throw StateError("message not resolved");
    for (var field in _fieldList) {
      var typeGen = field.baseType.generator;
      if (typeGen is EnumGenerator) {
        enumImports.add(typeGen.fileGen);
      } else if (typeGen != null) {
        imports.add(typeGen.fileGen);
      }
    }
    for (var m in _messageGenerators) {
      m.addImportsTo(imports, enumImports);
    }
    for (var x in _extensionGenerators) {
      x.addImportsTo(imports, enumImports);
    }
  }

  // Returns the number of enums in this message and all nested messages.
  int get enumCount {
    var count = _enumGenerators.length;
    for (var m in _messageGenerators) {
      count += m.enumCount;
    }
    return count;
  }

  /// Adds dependencies of [generateConstants] to [imports].
  ///
  /// For each .pbjson.dart file that the generated code needs to import,
  /// add its generator.
  void addConstantImportsTo(Set<FileGenerator> imports) {
    if (_fieldList == null) throw StateError("message not resolved");
    for (var m in _messageGenerators) {
      m.addConstantImportsTo(imports);
    }
    for (var x in _extensionGenerators) {
      x.addConstantImportsTo(imports);
    }
  }

  void generate(IndentingWriter out) {
    checkResolved();

    for (MessageGenerator m in _messageGenerators) {
      // Don't output the generated map entry type. Instead, the `PbMap` type
      // from the protobuf library is used to hold the keys and values.
      if (m._descriptor.options.hasMapEntry()) continue;
      m.generate(out);
    }

    for (OneofNames oneof in _oneofNames) {
      OneofEnumGenerator.generate(
          out, oneof.oneofEnumName, _oneofFields[oneof.index]);
    }

    var mixinClause = '';
    if (mixin != null) {
      var mixinNames = mixin.findMixinsToApply().map((m) => m.name);
      mixinClause = ' with ${mixinNames.join(", ")}';
    }

    String packageClause = package == ''
        ? ''
        : ', package: const $_protobufImportPrefix.PackageName(\'$package\')';
    out.addAnnotatedBlock(
        'class ${classname} extends $_protobufImportPrefix.GeneratedMessage${mixinClause} {',
        '}', [
      NamedLocation(
          name: classname, fieldPathSegment: fieldPath, start: 'class '.length)
    ], () {
      for (OneofNames oneof in _oneofNames) {
        out.addBlock(
            'static const $_coreImportPrefix.Map<$_coreImportPrefix.int, ${oneof.oneofEnumName}> ${oneof.byTagMapName} = {',
            '};', () {
          for (ProtobufField field in _oneofFields[oneof.index]) {
            final oneofMemberName =
                oneofEnumMemberName(field.memberNames.fieldName);
            out.println(
                '${field.number} : ${oneof.oneofEnumName}.${oneofMemberName},');
          }
          out.println('0 : ${oneof.oneofEnumName}.notSet');
        });
      }
      out.addBlock(
          'static final $_protobufImportPrefix.BuilderInfo _i = '
              '$_protobufImportPrefix.BuilderInfo(\'${messageName}\'$packageClause)',
          ';', () {
        for (int oneof = 0; oneof < _oneofFields.length; oneof++) {
          List<int> tags =
              _oneofFields[oneof].map((ProtobufField f) => f.number).toList();
          out.println("..oo($oneof, ${tags})");
        }

        for (ProtobufField field in _fieldList) {
          var dartFieldName = field.memberNames.fieldName;
          out.println(
              field.generateBuilderInfoCall(fileGen, dartFieldName, package));
        }

        if (_descriptor.extensionRange.isNotEmpty) {
          out.println('..hasExtensions = true');
        }
        if (!_hasRequiredFields(this, Set())) {
          out.println('..hasRequiredFields = false');
        }
      });

      for (ExtensionGenerator x in _extensionGenerators) {
        x.generate(out);
      }

      out.println();

      out.printlnAnnotated('${classname}._() : super();', [
        NamedLocation(name: classname, fieldPathSegment: fieldPath, start: 0)
      ]);
      out.println('factory ${classname}() => create();');
      out.println(
          'factory ${classname}.fromBuffer($_coreImportPrefix.List<$_coreImportPrefix.int> i,'
          ' [$_protobufImportPrefix.ExtensionRegistry r = $_protobufImportPrefix.ExtensionRegistry.EMPTY])'
          ' => create()..mergeFromBuffer(i, r);');
      out.println('factory ${classname}.fromJson($_coreImportPrefix.String i,'
          ' [$_protobufImportPrefix.ExtensionRegistry r = $_protobufImportPrefix.ExtensionRegistry.EMPTY])'
          ' => create()..mergeFromJson(i, r);');
      out.println('${classname} clone() =>'
          ' ${classname}()..mergeFromMessage(this);');
      out.println('$classname copyWith(void Function($classname) updates) =>'
          ' super.copyWith((message) => updates(message as $classname));');

      out.println('$_protobufImportPrefix.BuilderInfo get info_ => _i;');

      // Factory functions which can be used as default value closures.
      out.println("@${_coreImportPrefix}.pragma('dart2js:noInline')");
      out.println('static ${classname} create() => ${classname}._();');
      out.println('${classname} createEmptyInstance() => create();');

      out.println(
          'static $_protobufImportPrefix.PbList<${classname}> createRepeated() =>'
          ' $_protobufImportPrefix.PbList<${classname}>();');
      out.println("@${_coreImportPrefix}.pragma('dart2js:noInline')");
      out.println(
      'static ${classname} getDefault() =>'
        ' _defaultInstance ??='
        ' $_protobufImportPrefix.GeneratedMessage.\$_defaultFor<${classname}>'
        '(create);');
      out.println('static ${classname} _defaultInstance;');
      generateFieldsAccessorsMutators(out);
      wellKnownTypeForFullName(fullName)?.generateMethods(out);
    });
    out.println();
  }

  // Returns true if the message type has any required fields.  If it doesn't,
  // we can optimize out calls to its isInitialized()/_findInvalidFields()
  // methods.
  //
  // already_seen is used to avoid checking the same type multiple times
  // (and also to protect against unbounded recursion).
  bool _hasRequiredFields(MessageGenerator type, Set alreadySeen) {
    if (type._fieldList == null) throw StateError("message not resolved");

    if (alreadySeen.contains(type.fullName)) {
      // The type is already in cache.  This means that either:
      // a. The type has no required fields.
      // b. We are in the midst of checking if the type has required fields,
      //    somewhere up the stack.  In this case, we know that if the type
      //    has any required fields, they'll be found when we return to it,
      //    and the whole call to HasRequiredFields() will return true.
      //    Therefore, we don't have to check if this type has required fields
      //    here.
      return false;
    }
    alreadySeen.add(type.fullName);
    // If the type has extensions, an extension with message type could contain
    // required fields, so we have to be conservative and assume such an
    // extension exists.
    if (type._descriptor.extensionRange.isNotEmpty) {
      return true;
    }

    for (ProtobufField field in type._fieldList) {
      if (field.isRequired) {
        return true;
      }
      if (field.baseType.isMessage) {
        MessageGenerator child = field.baseType.generator;
        if (_hasRequiredFields(child, alreadySeen)) {
          return true;
        }
      }
    }
    return false;
  }

  void generateFieldsAccessorsMutators(IndentingWriter out) {
    _oneofNames
        .forEach((OneofNames oneof) => generateOneofAccessors(out, oneof));

    for (var field in _fieldList) {
      out.println();
      List<int> memberFieldPath = List.from(fieldPath)
        ..addAll([_messageFieldTag, field.sourcePosition]);
      generateFieldAccessorsMutators(field, out, memberFieldPath);
    }
  }

  void generateOneofAccessors(IndentingWriter out, OneofNames oneof) {
    out.println();
    out.println("${oneof.oneofEnumName} ${oneof.whichOneofMethodName}() "
        "=> ${oneof.byTagMapName}[\$_whichOneof(${oneof.index})];");
    out.println('void ${oneof.clearMethodName}() '
        '=> clearField(\$_whichOneof(${oneof.index}));');
  }

  void generateFieldAccessorsMutators(
      ProtobufField field, IndentingWriter out, List<int> memberFieldPath) {
    var fieldTypeString = field.getDartType(fileGen);
    var defaultExpr = field.getDefaultExpr();
    var names = field.memberNames;

    _emitDeprecatedIf(field.isDeprecated, out);
    _emitOverrideIf(field.overridesGetter, out);
    final getterExpr = _getterExpression(fieldTypeString, field.index,
        defaultExpr, field.isRepeated, field.isMapField);
    out.printlnAnnotated(
        '${fieldTypeString} get ${names.fieldName} => ${getterExpr};', [
      NamedLocation(
          name: names.fieldName,
          fieldPathSegment: memberFieldPath,
          start: '${fieldTypeString} get '.length)
    ]);

    if (field.isRepeated) {
      if (field.overridesSetter) {
        throw 'Field ${field.fullName} cannot override a setter for '
            '${names.fieldName} because it is repeated.';
      }
      if (field.overridesHasMethod) {
        throw 'Field ${field.fullName} cannot override '
            '${names.hasMethodName}() because it is repeated.';
      }
      if (field.overridesClearMethod) {
        throw 'Field ${field.fullName} cannot override '
            '${names.clearMethodName}() because it is repeated.';
      }
    } else {
      var fastSetter = field.baseType.setter;
      _emitDeprecatedIf(field.isDeprecated, out);
      _emitOverrideIf(field.overridesSetter, out);
      if (fastSetter != null) {
        out.printlnAnnotated(
            'set ${names.fieldName}'
            '($fieldTypeString v) { '
            '$fastSetter(${field.index}, v);'
            ' }',
            [
              NamedLocation(
                  name: names.fieldName,
                  fieldPathSegment: memberFieldPath,
                  start: 'set '.length)
            ]);
      } else {
        out.printlnAnnotated(
            'set ${names.fieldName}'
            '($fieldTypeString v) { '
            'setField(${field.number}, v);'
            ' }',
            [
              NamedLocation(
                  name: names.fieldName,
                  fieldPathSegment: memberFieldPath,
                  start: 'set '.length)
            ]);
      }
      _emitDeprecatedIf(field.isDeprecated, out);
      _emitOverrideIf(field.overridesHasMethod, out);
      out.printlnAnnotated(
          '$_coreImportPrefix.bool ${names.hasMethodName}() =>'
          ' \$_has(${field.index});',
          [
            NamedLocation(
                name: names.hasMethodName,
                fieldPathSegment: memberFieldPath,
                start: '$_coreImportPrefix.bool '.length)
          ]);
      _emitDeprecatedIf(field.isDeprecated, out);
      _emitOverrideIf(field.overridesClearMethod, out);
      out.printlnAnnotated(
          'void ${names.clearMethodName}() =>'
          ' clearField(${field.number});',
          [
            NamedLocation(
                name: names.clearMethodName,
                fieldPathSegment: memberFieldPath,
                start: 'void '.length)
          ]);
    }
  }

  String _getterExpression(String fieldType, int index, String defaultExpr,
      bool isRepeated, bool isMapField) {
    if (isMapField) {
      return '\$_getMap($index)';
    }
    if (fieldType == '$_coreImportPrefix.String') {
      if (defaultExpr == '""' || defaultExpr == "''") {
        return '\$_getSZ($index)';
      }
      return '\$_getS($index, $defaultExpr)';
    }
    if (fieldType == '$_coreImportPrefix.bool') {
      if (defaultExpr == 'false') {
        return '\$_getBF($index)';
      }
      return '\$_getB($index, $defaultExpr)';
    }
    if (fieldType == '$_coreImportPrefix.int') {
      if (defaultExpr == '0') {
        return '\$_getIZ($index)';
      }
      return '\$_getI($index, $defaultExpr)';
    }
    if (fieldType == 'Int64' && defaultExpr == 'null') {
      return '\$_getI64($index)';
    }
    if (defaultExpr == 'null') {
      return isRepeated ? '\$_getList($index)' : '\$_getN($index)';
    }
    return '\$_get($index, $defaultExpr)';
  }

  void _emitDeprecatedIf(bool condition, IndentingWriter out) {
    if (condition) {
      out.println(
          '@$_coreImportPrefix.Deprecated(\'This field is deprecated.\')');
    }
  }

  void _emitOverrideIf(bool condition, IndentingWriter out) {
    if (condition) {
      out.println('@$_coreImportPrefix.override');
    }
  }

  void generateEnums(IndentingWriter out) {
    for (EnumGenerator e in _enumGenerators) {
      e.generate(out);
    }

    for (MessageGenerator m in _messageGenerators) {
      m.generateEnums(out);
    }
  }

  /// Writes a Dart constant containing the JSON for the ProtoDescriptor.
  /// Also writes a separate constant for each nested message,
  /// to avoid duplication.
  void generateConstants(IndentingWriter out) {
    const nestedTypeTag = 3;
    const enumTypeTag = 4;
    assert(_descriptor.info_.fieldInfo[nestedTypeTag].name == "nestedType");
    assert(_descriptor.info_.fieldInfo[enumTypeTag].name == "enumType");

    var name = getJsonConstant(fileGen);
    var json = _descriptor.writeToJsonMap();
    var nestedTypeNames =
        _messageGenerators.map((m) => m.getJsonConstant(fileGen)).toList();
    var nestedEnumNames =
        _enumGenerators.map((e) => e.getJsonConstant(fileGen)).toList();

    out.addBlock("const $name = const {", "};", () {
      for (var key in json.keys) {
        out.print("'$key': ");
        if (key == "$nestedTypeTag") {
          // refer to message constants by name instead of repeating each value
          out.println("const [${nestedTypeNames.join(", ")}],");
          continue;
        } else if (key == "$enumTypeTag") {
          // refer to enum constants by name
          out.println("const [${nestedEnumNames.join(", ")}],");
          continue;
        }
        writeJsonConst(out, json[key]);
        out.println(",");
      }
    });
    out.println();

    for (var m in _messageGenerators) {
      m.generateConstants(out);
    }

    for (var e in _enumGenerators) {
      e.generateConstants(out);
    }
  }
}
