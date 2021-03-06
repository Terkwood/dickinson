scriptencoding utf-8

if exists('b:current_syntax')
    finish
endif

syntax match dickinsonSymbol ":"

syntax match dickinsonIdentifier "\v[a-zA-Z0-9]+"

syntax match dickinsonNum "\v[0-9]+"
syntax match dickinsonNum "\v[0-9]+\.[0-9]+"

syntax match dickinsonKeyword ":include"
syntax match dickinsonKeyword ":def"
syntax match dickinsonKeyword ":branch"
syntax match dickinsonKeyword ":oneof"
syntax match dickinsonKeyword ":let"
syntax match dickinsonKeyword ":lambda"
syntax match dickinsonKeyword ":match"
syntax match dickinsonKeyword ":flatten"
syntax match dickinsonKeyword "tydecl"
syntax match dickinsonKeyword ":pick"
syntax match dickinsonKeyword ":bind"

syntax match dickinsonEsc +\\["\\n]+

syntax match dickinsonType "text"

syntax region dickinsonInterpolation start='${' end='}' contains=dickinsonIdentifier,dickinsonKeyword,dickinsonType,dickinsonString

syntax region dickinsonString start=+"+ end=+"+ contains=@Spell,dickinsonEsc,dickinsonInterpolation
syntax region dickinsonString start=+'''+ end=+'''+ contains=@Spell,dickinsonInterpolation

syntax match dickinsonComment "\v;.*$" contains=@Spell
syntax match dickinsonComment "\v#!.*$"

syntax match dickinsonSymbol ">"
syntax match dickinsonSymbol "\$"
syntax match dickinsonSymbol "%-"
syntax match dickinsonSymbol "⟶"
syntax match dickinsonSymbol "->"

syntax match dickinsonBuiltin "oulipo"
syntax match dickinsonBuiltin "allCaps"
syntax match dickinsonBuiltin "capitalize"
syntax match dickinsonBuiltin "titlecase"

highlight link dickinsonComment Comment
highlight link dickinsonInterpolation Special
highlight link dickinsonKeyword Keyword
highlight link dickinsonNum Number
highlight link dickinsonIdentifier Identifier
highlight link dickinsonString String
highlight link dickinsonType Type
highlight link dickinsonSymbol Special
highlight link dickinsonEsc Special
highlight link dickinsonBuiltin Underlined

let b:current_syntax = 'dickinson'
