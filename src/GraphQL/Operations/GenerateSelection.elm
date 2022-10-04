module GraphQL.Operations.GenerateSelection exposing (generate)

{-| Generate elm code from an Operations.AST
-}

import Dict
import Elm
import Elm.Annotation as Type
import Elm.Case
import Elm.Op
import Gen.GraphQL.Engine as Engine
import Gen.Json.Decode as Decode
import Generate.Input as Input
import Generate.Input.Encode
import GraphQL.Operations.AST as AST
import GraphQL.Operations.CanonicalAST as Can
import GraphQL.Schema
import Set
import Utils.String


type alias Namespace =
    { namespace : String
    , enums : String
    }


generate :
    { namespace : Namespace
    , schema : GraphQL.Schema.Schema
    , document : Can.Document

    -- all the dirs between CWD and the GQL file
    , path : List String

    -- all the directories between the Elm source folder and the GQL file
    , elmBase : List String
    }
    -> List Elm.File
generate opts =
    List.map (generateDefinition opts) opts.document.definitions


opTypeName : Can.OperationType -> String
opTypeName op =
    case op of
        Can.Query ->
            "Query"

        Can.Mutation ->
            "Mutation"


opValueName : Can.OperationType -> String
opValueName op =
    case op of
        Can.Query ->
            "query"

        Can.Mutation ->
            "mutation"


option =
    { annotation =
        Engine.annotation_.option
    , absent =
        Engine.make_.absent
    , null =
        Engine.make_.null
    , present =
        Engine.make_.present
    }


toArgument : Can.VariableDefinition -> GraphQL.Schema.Argument
toArgument varDef =
    -- if the declared type is required, and the schema is optional
    -- adjust the schema type to also be required for this variable defintiion
    -- This will make the generated code cleaner
    let
        adjustedSchemaType =
            case varDef.type_ of
                AST.Nullable _ ->
                    varDef.schemaType

                _ ->
                    case varDef.schemaType of
                        GraphQL.Schema.Nullable schemaType ->
                            schemaType

                        _ ->
                            varDef.schemaType
    in
    { name = Can.nameToString varDef.variable.name
    , description = Nothing
    , type_ = adjustedSchemaType
    }


generateDefinition :
    { namespace : Namespace
    , schema : GraphQL.Schema.Schema
    , document : Can.Document

    -- all the dirs between CWD and the GQL file
    , path : List String

    -- all the directories between CWD and the Elm root
    , elmBase : List String
    }
    -> Can.Definition
    -> Elm.File
generateDefinition { namespace, schema, document, path, elmBase } ((Can.Operation op) as def) =
    let
        opName =
            Maybe.withDefault (opTypeName op.operationType)
                (Maybe.map
                    Can.nameToString
                    op.name
                )

        arguments =
            List.map toArgument op.variableDefinitions

        -- The path between elm root and the gql file
        pathFromElmRootToGqlFile =
            path |> removePrefix elmBase

        input =
            case op.variableDefinitions of
                [] ->
                    []

                _ ->
                    List.concat
                        [ [ Elm.comment """  Inputs """
                          , Generate.Input.Encode.toRecordInput namespace
                                schema
                                arguments
                          ]
                        , Generate.Input.Encode.toRecordOptionals namespace
                            schema
                            arguments
                        , Generate.Input.Encode.toRecordNulls arguments
                        , [ Generate.Input.Encode.toInputRecordAlias namespace schema "Input" arguments
                          ]
                        ]

        query =
            case op.variableDefinitions of
                [] ->
                    [ Elm.declaration (opValueName op.operationType)
                        (Engine.bakeToSelection
                            (case Can.operationLabel def of
                                Nothing ->
                                    Elm.nothing

                                Just label ->
                                    Elm.just (Elm.string label)
                            )
                            (\version ->
                                Elm.tuple
                                    (Elm.list [])
                                    (Can.toRendererExpression version def)
                            )
                            (\version -> generateDecoder version namespace def)
                            |> Elm.withType
                                (Type.namedWith [ namespace.namespace ]
                                    (opTypeName op.operationType)
                                    [ Type.named [] opName ]
                                )
                        )
                        |> Elm.exposeWith { exposeConstructor = True, group = Just "query" }
                    ]

                _ ->
                    [ Elm.fn
                        ( "args"
                        , Just (Type.named [] "Input")
                        )
                        (\args ->
                            let
                                vars =
                                    Generate.Input.Encode.fullRecordToInputObject
                                        namespace
                                        schema
                                        arguments
                                        args
                                        |> Engine.inputObjectToFieldList
                            in
                            Engine.bakeToSelection
                                (case Can.operationLabel def of
                                    Nothing ->
                                        Elm.nothing

                                    Just label ->
                                        Elm.just (Elm.string label)
                                )
                                (\version ->
                                    Elm.tuple
                                        vars
                                        (Can.toRendererExpression version def)
                                )
                                (\version ->
                                    generateDecoder version namespace def
                                )
                                |> Elm.withType
                                    (Type.namedWith [ namespace.namespace ]
                                        (opTypeName op.operationType)
                                        [ Type.named [] opName ]
                                    )
                        )
                        |> Elm.declaration (opValueName op.operationType)
                        |> Elm.exposeWith { exposeConstructor = True, group = Just "query" }
                    ]

        fragmentDecoders =
            generateFragmentDecoders namespace document.fragments

        -- auxHelpers are record alises that aren't *essential* to the return type,
        -- but are useful in some cases
        auxHelpers =
            aliasedTypes namespace def

        primaryResult =
            -- if we no longer want aliased versions, there's also one without aliases
            Elm.comment """ Return data """
                :: generatePrimaryResultTypeAliased namespace def
    in
    Elm.fileWith (pathFromElmRootToGqlFile ++ [ opName ])
        { aliases = []
        , docs =
            \docs ->
                [ """This file is generated from a `.gql` file, likely in a nearby folder.

Please avoid modifying directly :)

This file can be regenerated by running `elm-gql`

""" ++ renderStandardComment docs
                ]
        }
        (input
            ++ primaryResult
            ++ auxHelpers
            ++ query
            ++ fragmentDecoders
        )
        |> modifyFilePath (path ++ [ opName ])


removePrefix prefix list =
    case prefix of
        [] ->
            list

        pref :: remainPref ->
            case list of
                [] ->
                    list

                first :: remain ->
                    removePrefix remainPref remain


modifyFilePath : List String -> { a | path : String } -> { a | path : String }
modifyFilePath pieces file =
    { file
        | path = String.join "/" pieces ++ ".elm"
    }


renderStandardComment :
    List
        { group : Maybe String
        , members : List String
        }
    -> String
renderStandardComment groups =
    if List.isEmpty groups then
        ""

    else
        List.foldl
            (\grouped str ->
                str ++ "@docs " ++ String.join ", " grouped.members ++ "\n\n"
            )
            "\n\n"
            groups


andMap : Elm.Expression -> Elm.Expression -> Elm.Expression
andMap decoder builder =
    builder
        |> Elm.Op.pipe
            (Elm.apply
                Engine.values_.andMap
                [ decoder
                ]
            )



{- RESULT DATA -}


generatePrimaryResultType : Namespace -> Can.Definition -> List Elm.Declaration
generatePrimaryResultType namespace def =
    case def of
        Can.Operation op ->
            let
                record =
                    List.foldl
                        (\field allFields ->
                            let
                                new =
                                    fieldAnnotation
                                        namespace
                                        field
                            in
                            new ++ allFields
                        )
                        []
                        op.fields
                        |> List.reverse
                        |> Type.record
            in
            [ Elm.alias
                (Maybe.withDefault "Query"
                    (Maybe.map
                        Can.nameToString
                        op.name
                    )
                )
                record
                |> Elm.exposeWith { exposeConstructor = True, group = Just "necessary" }
            ]


generatePrimaryResultTypeAliased : Namespace -> Can.Definition -> List Elm.Declaration
generatePrimaryResultTypeAliased namespace def =
    case def of
        Can.Operation op ->
            let
                record =
                    List.foldl (aliasedFieldRecord namespace)
                        []
                        op.fields
                        |> List.reverse
                        |> Type.record
            in
            [ Elm.alias
                (Maybe.withDefault "Query"
                    (Maybe.map
                        Can.nameToString
                        op.name
                    )
                )
                record
                |> Elm.exposeWith
                    { exposeConstructor = True
                    , group = Just "necessary"
                    }
            ]


generateTypesForFields fn generated fields =
    case fields of
        [] ->
            generated

        top :: remaining ->
            let
                newStuff =
                    fn top
            in
            generateTypesForFields fn
                (generated ++ newStuff)
                remaining


aliasedTypes : Namespace -> Can.Definition -> List Elm.Declaration
aliasedTypes namespace def =
    case def of
        Can.Operation op ->
            generateTypesForFields
                (genAliasedTypes namespace)
                []
                op.fields


genAliasedTypes : Namespace -> Can.Field -> List Elm.Declaration
genAliasedTypes namespace fieldOrFrag =
    case fieldOrFrag of
        Can.Frag frag ->
            let
                name =
                    Can.nameToString frag.fragment.name
            in
            case frag.fragment.selection of
                Can.FragmentObject { selection } ->
                    let
                        newDecls =
                            generateTypesForFields (genAliasedTypes namespace)
                                []
                                selection

                        -- fieldResult =
                        --     List.foldl (aliasedFieldRecord namespace)
                        --         []
                        --         selection
                        --         |> List.reverse
                        --         |> Type.record
                    in
                    -- (Elm.alias name fieldResult
                    --     |> Elm.expose
                    -- )
                    --     ::
                    newDecls

                Can.FragmentUnion union ->
                    let
                        newDecls =
                            generateTypesForFields (genAliasedTypes namespace)
                                []
                                union.selection

                        final =
                            List.foldl
                                (unionVars namespace)
                                { variants = []
                                , declarations = []
                                }
                                union.variants

                        ghostVariants =
                            List.map (Elm.variant << unionVariantName) union.remainingTags

                        -- Any records within variants
                    in
                    (Elm.customType
                        name
                        (final.variants ++ ghostVariants)
                        |> Elm.exposeWith
                            { exposeConstructor = True
                            , group = Just "unions"
                            }
                    )
                        :: final.declarations
                        ++ newDecls

                Can.FragmentInterface interface ->
                    let
                        newDecls =
                            generateTypesForFields (genAliasedTypes namespace)
                                []
                                interface.selection

                        selectingForVariants =
                            case interface.variants of
                                [] ->
                                    False

                                _ ->
                                    True

                        final =
                            List.foldl
                                (interfaceVariants namespace)
                                { variants = []
                                , declarations = []
                                }
                                interface.variants

                        withSpecificType existingList =
                            if selectingForVariants then
                                let
                                    ghostVariants =
                                        List.map (Elm.variant << unionVariantName) interface.remainingTags
                                in
                                (Elm.customType
                                    (name ++ "_Specifics")
                                    (final.variants ++ ghostVariants)
                                    |> Elm.exposeWith
                                        { exposeConstructor = True
                                        , group = Just "unions"
                                        }
                                )
                                    :: existingList

                            else
                                existingList
                    in
                    withSpecificType
                        (final.declarations
                            ++ newDecls
                        )

        Can.Field field ->
            let
                name =
                    Can.nameToString field.globalAlias
            in
            case field.selection of
                Can.FieldObject selection ->
                    let
                        newDecls =
                            generateTypesForFields (genAliasedTypes namespace)
                                []
                                selection

                        fieldResult =
                            List.foldl (aliasedFieldRecord namespace)
                                []
                                selection
                                |> List.reverse
                                |> Type.record
                    in
                    (Elm.alias name fieldResult
                        |> Elm.expose
                    )
                        :: newDecls

                Can.FieldUnion union ->
                    let
                        newDecls =
                            generateTypesForFields (genAliasedTypes namespace)
                                []
                                union.selection

                        final =
                            List.foldl
                                (unionVars namespace)
                                { variants = []
                                , declarations = []
                                }
                                union.variants

                        ghostVariants =
                            List.map (Elm.variant << unionVariantName) union.remainingTags

                        -- Any records within variants
                    in
                    (Elm.customType
                        name
                        (final.variants ++ ghostVariants)
                        |> Elm.exposeWith
                            { exposeConstructor = True
                            , group = Just "unions"
                            }
                    )
                        :: final.declarations
                        ++ newDecls

                Can.FieldInterface interface ->
                    let
                        newDecls =
                            generateTypesForFields (genAliasedTypes namespace)
                                []
                                interface.selection

                        selectingForVariants =
                            case interface.variants of
                                [] ->
                                    False

                                _ ->
                                    True

                        -- Generate the record
                        interfaceRecord =
                            List.foldl (aliasedFieldRecord namespace)
                                (if selectingForVariants then
                                    [ ( "specifics_"
                                      , Type.named [] (name ++ "_Specifics")
                                      )
                                    ]

                                 else
                                    []
                                )
                                interface.selection
                                |> Type.record

                        final =
                            List.foldl
                                (interfaceVariants namespace)
                                { variants = []
                                , declarations = []
                                }
                                interface.variants

                        ghostVariants =
                            List.map (Elm.variant << unionVariantName) interface.remainingTags

                        withSpecificType existingList =
                            if selectingForVariants then
                                (Elm.customType
                                    (name ++ "_Specifics")
                                    (final.variants ++ ghostVariants)
                                    |> Elm.exposeWith
                                        { exposeConstructor = True
                                        , group = Just "unions"
                                        }
                                )
                                    :: existingList

                            else
                                existingList
                    in
                    (Elm.alias name interfaceRecord
                        |> Elm.exposeWith { exposeConstructor = True, group = Just "necessary" }
                    )
                        :: withSpecificType
                            (final.declarations
                                ++ newDecls
                            )

                _ ->
                    []


unionVariantName tag =
    Can.nameToString tag.globalAlias


aliasedFieldRecord :
    Namespace
    -> Can.Field
    -> List ( String, Type.Annotation )
    -> List ( String, Type.Annotation )
aliasedFieldRecord namespace sel fields =
    if Can.isTypeNameSelection sel then
        -- skip it!
        fields

    else
        fieldAliasedAnnotation namespace sel ++ fields


fieldAliasedAnnotation :
    Namespace
    -> Can.Field
    -> List ( String, Type.Annotation )
fieldAliasedAnnotation namespace field =
    if Can.isTypeNameSelection field then
        []

    else
        case field of
            Can.Field details ->
                [ ( Can.getAliasedName details
                  , selectionAliasedAnnotation namespace details
                        |> Input.wrapElmType details.wrapper
                  )
                ]

            Can.Frag frag ->
                case frag.fragment.selection of
                    Can.FragmentObject { selection } ->
                        List.concatMap
                            (fieldAliasedAnnotation namespace)
                            selection

                    Can.FragmentUnion union ->
                        List.concatMap
                            (fieldAliasedAnnotation namespace)
                            union.selection

                    Can.FragmentInterface interface ->
                        if not (List.isEmpty interface.variants) || not (List.isEmpty interface.remainingTags) then
                            let
                                name =
                                    Can.nameToString frag.fragment.name
                            in
                            List.concatMap
                                (fieldAliasedAnnotation namespace)
                                interface.selection
                                ++ [ ( name, Type.named [] (name ++ "_Specifics") )
                                   ]

                        else
                            List.concatMap
                                (fieldAliasedAnnotation namespace)
                                interface.selection


selectionAliasedAnnotation :
    Namespace
    -> Can.FieldDetails
    -> Type.Annotation
selectionAliasedAnnotation namespace field =
    case field.selection of
        Can.FieldObject obj ->
            Type.named
                []
                (Can.nameToString field.globalAlias)

        Can.FieldScalar type_ ->
            schemaTypeToPrefab type_

        Can.FieldEnum enum ->
            enumType namespace enum.enumName

        Can.FieldUnion _ ->
            Type.named
                []
                (Can.nameToString field.globalAlias)

        Can.FieldInterface _ ->
            Type.named
                []
                (Can.nameToString field.globalAlias)


{-| -}
unionVars :
    Namespace
    -> Can.VariantCase
    ->
        { variants : List Elm.Variant
        , declarations : List Elm.Declaration
        }
    ->
        { variants : List Elm.Variant
        , declarations : List Elm.Declaration
        }
unionVars namespace unionCase gathered =
    case List.filter removeTypename unionCase.selection of
        [] ->
            { declarations = gathered.declarations
            , variants =
                Elm.variant
                    (Can.nameToString unionCase.globalTagName)
                    :: gathered.variants
            }

        fields ->
            let
                record =
                    List.foldl (aliasedFieldRecord namespace)
                        []
                        fields
                        |> List.reverse
                        |> Type.record

                variantName =
                    Can.nameToString unionCase.globalTagName

                detailsName =
                    Can.nameToString unionCase.globalDetailsAlias

                recordAlias =
                    Elm.alias detailsName record
                        |> Elm.exposeWith
                            { exposeConstructor = True
                            , group = Just "necessary"
                            }

                -- aliases for subselections
                subfieldAliases =
                    generateTypesForFields (genAliasedTypes namespace)
                        []
                        fields
            in
            { variants =
                Elm.variantWith
                    variantName
                    [ Type.named [] detailsName
                    ]
                    :: gathered.variants
            , declarations =
                Elm.comment (Can.nameToString unionCase.tag)
                    :: recordAlias
                    :: subfieldAliases
                    ++ gathered.declarations
            }


{-| -}
interfaceVariants :
    Namespace
    -> Can.VariantCase
    ->
        { variants : List Elm.Variant
        , declarations : List Elm.Declaration
        }
    ->
        { variants : List Elm.Variant
        , declarations : List Elm.Declaration
        }
interfaceVariants namespace unionCase gathered =
    case List.filter removeTypename unionCase.selection of
        [] ->
            { variants =
                Elm.variant
                    (Can.nameToString unionCase.globalTagName)
                    :: gathered.variants
            , declarations = gathered.declarations
            }

        fields ->
            let
                record =
                    List.foldl (aliasedFieldRecord namespace)
                        []
                        fields
                        |> List.reverse
                        |> Type.record

                detailsName =
                    Can.nameToString unionCase.globalDetailsAlias

                recordAlias =
                    Elm.alias detailsName record
                        |> Elm.exposeWith
                            { exposeConstructor = True
                            , group = Just "necessary"
                            }

                -- aliases for subselections
                subfieldAliases =
                    generateTypesForFields (genAliasedTypes namespace)
                        []
                        fields
            in
            { variants =
                Elm.variantWith
                    (Can.nameToString unionCase.globalTagName)
                    [ Type.named [] detailsName
                    ]
                    :: gathered.variants
            , declarations =
                Elm.comment (Can.nameToString unionCase.tag)
                    :: recordAlias
                    :: subfieldAliases
                    ++ gathered.declarations
            }


removeTypename : Can.Field -> Bool
removeTypename field =
    case field of
        Can.Field details ->
            Can.nameToString details.name /= "__typename"

        _ ->
            True


fieldAnnotation :
    Namespace
    -> Can.Field
    -> List ( String, Type.Annotation )
fieldAnnotation namespace field =
    case field of
        Can.Field details ->
            [ ( Can.getAliasedName details
              , selectionAnnotation namespace details details.selection
                    |> Input.wrapElmType details.wrapper
              )
            ]

        Can.Frag frag ->
            case frag.fragment.selection of
                Can.FragmentObject { selection } ->
                    List.concatMap
                        (fieldAnnotation namespace)
                        selection

                Can.FragmentUnion union ->
                    List.concatMap
                        (fieldAnnotation namespace)
                        union.selection

                Can.FragmentInterface interface ->
                    List.concatMap
                        (fieldAnnotation namespace)
                        interface.selection


selectionAnnotation :
    Namespace
    -> Can.FieldDetails
    -> Can.Selection
    -> Type.Annotation
selectionAnnotation namespace field selection =
    case selection of
        Can.FieldObject objSelection ->
            let
                record =
                    List.foldl
                        (\subfield allFields ->
                            let
                                newFields =
                                    fieldAnnotation
                                        namespace
                                        subfield
                            in
                            newFields ++ allFields
                        )
                        []
                        objSelection
                        |> List.reverse
                        |> Type.record
            in
            record

        Can.FieldScalar type_ ->
            schemaTypeToPrefab type_

        Can.FieldEnum enum ->
            enumType namespace enum.enumName

        Can.FieldUnion union ->
            Type.named
                []
                (Can.getAliasedName field)

        Can.FieldInterface interface ->
            Type.named
                []
                (Can.getAliasedName field)


enumType : Namespace -> String -> Type.Annotation
enumType namespace enumName =
    Type.named
        [ namespace.enums
        , "Enum"
        , Utils.String.formatTypename enumName
        ]
        enumName


schemaTypeToPrefab : GraphQL.Schema.Type -> Type.Annotation
schemaTypeToPrefab schemaType =
    case schemaType of
        GraphQL.Schema.Scalar scalarName ->
            case String.toLower scalarName of
                "string" ->
                    Type.string

                "int" ->
                    Type.int

                "float" ->
                    Type.float

                "boolean" ->
                    Type.bool

                _ ->
                    Type.namedWith [ "Scalar" ]
                        (Utils.String.formatScalar scalarName)
                        []

        GraphQL.Schema.InputObject input ->
            Type.unit

        GraphQL.Schema.Object obj ->
            Type.unit

        GraphQL.Schema.Enum name ->
            Type.unit

        GraphQL.Schema.Union name ->
            Type.unit

        GraphQL.Schema.Interface name ->
            Type.unit

        GraphQL.Schema.List_ inner ->
            Type.list (schemaTypeToPrefab inner)

        GraphQL.Schema.Nullable inner ->
            Type.maybe (schemaTypeToPrefab inner)



{- DECODER -}


{-| -}
generateDecoder : Elm.Expression -> Namespace -> Can.Definition -> Elm.Expression
generateDecoder version namespace (Can.Operation op) =
    let
        opName =
            Maybe.withDefault "Query"
                (Maybe.map
                    Can.nameToString
                    op.name
                )
    in
    Decode.succeed
        (Elm.value
            { importFrom = []
            , name = opName
            , annotation = Nothing
            }
        )
        |> decodeFields namespace
            version
            initIndex
            op.fields


type Index
    = Index Int (List Int)


isTopLevel : Index -> Bool
isTopLevel (Index i tail) =
    List.isEmpty tail


indexToString : Index -> String
indexToString (Index top tail) =
    String.fromInt top ++ "_" ++ String.join "_" (List.map String.fromInt tail)


initIndex : Index
initIndex =
    Index 0 []


next : Index -> Index
next (Index top total) =
    Index (top + 1) total


child : Index -> Index
child (Index top total) =
    Index 0 (top :: total)


decodeFields : Namespace -> Elm.Expression -> Index -> List Can.Field -> Elm.Expression -> Elm.Expression
decodeFields namespace version index fields exp =
    List.foldl
        (decodeFieldHelper namespace version)
        ( index, exp )
        fields
        |> Tuple.second


decodeFieldHelper : Namespace -> Elm.Expression -> Can.Field -> ( Index, Elm.Expression ) -> ( Index, Elm.Expression )
decodeFieldHelper namespace version field ( index, exp ) =
    case field of
        Can.Field details ->
            ( next index
            , exp
                |> decodeSingleField version
                    index
                    (Can.getAliasedName details)
                    (decodeSelection
                        namespace
                        version
                        details
                        (child index)
                        |> Input.decodeWrapper details.wrapper
                    )
            )

        Can.Frag fragment ->
            ( index
            , exp
                |> Elm.Op.pipe
                    (Elm.value
                        { importFrom = []
                        , name = "fragments_"
                        , annotation = Nothing
                        }
                        |> Elm.get (Can.nameToString fragment.fragment.name)
                        |> Elm.get "decoder"
                    )
            )


decodeSelection : Namespace -> Elm.Expression -> Can.FieldDetails -> Index -> Elm.Expression
decodeSelection namespace version field index =
    case field.selection of
        Can.FieldObject objSelection ->
            Decode.succeed (Elm.val (Can.nameToString field.globalAlias))
                |> decodeFields namespace
                    version
                    (child index)
                    objSelection

        Can.FieldScalar type_ ->
            decodeScalarType type_

        Can.FieldEnum enum ->
            Elm.value
                { importFrom =
                    [ namespace.enums
                    , "Enum"
                    , Utils.String.formatTypename enum.enumName
                    ]
                , name = "decoder"
                , annotation =
                    Nothing
                }

        Can.FieldUnion union ->
            decodeUnion namespace
                version
                (child index)
                union

        Can.FieldInterface interface ->
            Decode.succeed (Elm.val (Can.nameToString field.globalAlias))
                |> decodeInterface namespace
                    version
                    (child index)
                    interface


decodeSingleField version index name decoder exp =
    exp
        |> Elm.Op.pipe
            (Elm.apply
                Engine.values_.versionedJsonField
                -- we only care about adjusting the aliases of the top-level things that could collide
                [ if isTopLevel index then
                    version

                  else
                    Elm.int 0
                , Elm.string name
                , decoder
                ]
            )


decodeInterface :
    Namespace
    -> Elm.Expression
    -> Index
    -> Can.FieldVariantDetails
    -> Elm.Expression
    -> Elm.Expression
decodeInterface namespace version index interface start =
    let
        selection =
            List.filter (not << Can.isTypeNameSelection) interface.selection
                |> List.reverse
    in
    case interface.variants of
        [] ->
            start
                |> decodeFields namespace version (child index) selection

        _ ->
            start
                |> decodeFields namespace version (child index) selection
                |> andMap (decodeInterfaceSpecifics namespace version index interface)


decodeInterfaceSpecifics : Namespace -> Elm.Expression -> Index -> Can.FieldVariantDetails -> Elm.Expression
decodeInterfaceSpecifics namespace version index interface =
    Decode.field "__typename" Decode.string
        |> Decode.andThen
            (\val ->
                Elm.Case.string val
                    { cases =
                        List.map
                            (interfacePattern namespace
                                version
                                (child index)
                                interface.selection
                            )
                            interface.variants
                            ++ List.map
                                (\tag ->
                                    ( Can.nameToString tag.tag
                                    , Decode.succeed
                                        (Elm.value
                                            { importFrom = []
                                            , name = unionVariantName tag
                                            , annotation = Nothing
                                            }
                                        )
                                    )
                                )
                                interface.remainingTags
                    , otherwise =
                        Decode.fail "Unknown interface type"
                    }
            )



-- interfacePattern : Namespace -> Elm.Expression -> Index ->


interfacePattern namespace version index commonFields var =
    let
        tag =
            Utils.String.formatTypename (Can.nameToString var.tag)

        tagTypeName =
            Can.nameToString var.globalTagName

        allFields =
            var.selection
    in
    ( tag
    , case List.filter removeTypename allFields of
        [] ->
            Decode.succeed
                (Elm.value
                    { importFrom = []
                    , name = tagTypeName
                    , annotation = Nothing
                    }
                )

        fields ->
            Decode.call_.map
                (Elm.val tagTypeName)
                (Decode.succeed
                    (Elm.val (Can.nameToString var.globalDetailsAlias))
                )
                |> decodeFields namespace version (child index) fields
    )


decodeUnion :
    Namespace
    -> Elm.Expression
    -> Index
    -> Can.FieldVariantDetails
    -> Elm.Expression
decodeUnion namespace version index union =
    Decode.field "__typename" Decode.string
        |> Decode.andThen
            (\typename ->
                Elm.Case.string typename
                    { cases =
                        List.map
                            (unionPattern namespace
                                version
                                (child index)
                            )
                            union.variants
                            ++ List.map
                                (\tag ->
                                    ( Can.nameToString tag.tag
                                    , Decode.succeed
                                        (Elm.value
                                            { importFrom = []
                                            , name = unionVariantName tag
                                            , annotation = Nothing
                                            }
                                        )
                                    )
                                )
                                union.remainingTags
                    , otherwise =
                        Decode.fail "Unknown union type"
                    }
            )


unionPattern namespace version index var =
    let
        tag =
            Utils.String.formatTypename (Can.nameToString var.tag)

        tagTypeName =
            Can.nameToString var.globalTagName

        tagDetailsName =
            Can.nameToString var.globalDetailsAlias
    in
    ( tag
    , case List.filter removeTypename var.selection of
        [] ->
            Decode.succeed
                (Elm.value
                    { importFrom = []
                    , name = tagTypeName
                    , annotation = Nothing
                    }
                )

        fields ->
            Decode.call_.map
                (Elm.value
                    { importFrom = []
                    , name = tagTypeName
                    , annotation = Nothing
                    }
                )
                (Decode.succeed
                    (Elm.value
                        { importFrom = []
                        , name = tagDetailsName
                        , annotation = Nothing
                        }
                    )
                    |> decodeFields namespace version (child index) fields
                )
    )


decodeScalarType : GraphQL.Schema.Type -> Elm.Expression
decodeScalarType type_ =
    case type_ of
        GraphQL.Schema.Scalar scalarName ->
            case String.toLower scalarName of
                "int" ->
                    Decode.int

                "float" ->
                    Decode.float

                "string" ->
                    Decode.string

                "boolean" ->
                    Decode.bool

                scal ->
                    Elm.value
                        { importFrom =
                            [ "Scalar" ]
                        , name = Utils.String.formatValue scalarName
                        , annotation =
                            Nothing
                        }
                        |> Elm.get "decoder"

        GraphQL.Schema.Nullable inner ->
            Decode.nullable (decodeScalarType inner)

        GraphQL.Schema.List_ inner ->
            Decode.list (decodeScalarType inner)

        _ ->
            Decode.succeed (Elm.string "DECODE UNKNOWN")



{- FRAGMENTS -}


generateFragmentDecoders : Namespace -> List Can.Fragment -> List Elm.Declaration
generateFragmentDecoders namespace fragments =
    let
        decoderRecord =
            List.map (genFragDecoder namespace) fragments
                |> Elm.record
                |> Elm.declaration "fragments_"
    in
    [ decoderRecord ]


{-|

    { name = Name
    , typeCondition = Name
    , directives = List Directive
    , selection = List Selection
    }

-}
genFragDecoder : Namespace -> Can.Fragment -> ( String, Elm.Expression )
genFragDecoder namespace frag =
    ( Can.nameToString frag.name
    , Elm.record
        [ ( "decoder"
          , case frag.selection of
                Can.FragmentObject fragSelection ->
                    Elm.fn ( "start_", Nothing )
                        (\start ->
                            decodeFields namespace
                                (Elm.int 0)
                                initIndex
                                fragSelection.selection
                                start
                        )

                Can.FragmentUnion fragSelection ->
                    Elm.fn ( "start_", Nothing )
                        (\start ->
                            start
                                |> decodeSingleField (Elm.int 0)
                                    initIndex
                                    (Can.nameToString frag.name)
                                    (decodeUnion namespace
                                        (Elm.int 0)
                                        initIndex
                                        fragSelection
                                    )
                        )

                Can.FragmentInterface fragSelection ->
                    Elm.fn ( "start_", Nothing )
                        (\start ->
                            start
                                |> decodeInterface namespace
                                    (Elm.int 0)
                                    initIndex
                                    fragSelection
                        )
          )
        ]
    )
