module Data.Text.Prettyprint.Doc.Ext ( prettyText
                                     , prettyLazyText
                                     , smartDickinson
                                     , dickinsonText
                                     , dickinsonLazyText
                                     -- * Operators
                                     , (<#>)
                                     , (<:>)
                                     , (<^>)
                                     ) where

import           Data.Semigroup                        ((<>))
import qualified Data.Text                             as T
import qualified Data.Text.Lazy                        as TL
import           Data.Text.Prettyprint.Doc             (Doc, LayoutOptions (LayoutOptions),
                                                        PageWidth (AvailablePerLine),
                                                        Pretty (pretty),
                                                        SimpleDocStream,
                                                        defaultLayoutOptions,
                                                        flatAlt, hardline,
                                                        indent, layoutSmart,
                                                        softline, (<+>))
import           Data.Text.Prettyprint.Doc.Render.Text (renderLazy,
                                                        renderStrict)

infixr 6 <#>
infixr 6 <:>
infixr 6 <^>

(<#>) :: Doc a -> Doc a -> Doc a
(<#>) x y = x <> hardline <> y

(<:>) :: Doc a -> Doc a -> Doc a
(<:>) x y = x <> softline <> y

(<^>) :: Doc a -> Doc a -> Doc a
(<^>) x y = flatAlt (x <> hardline <> indent 4 y) (x <+> y)

dickinsonLayoutOptions :: LayoutOptions
dickinsonLayoutOptions = LayoutOptions (AvailablePerLine 160 0.8)

smartDickinson :: Doc a -> SimpleDocStream a
smartDickinson = layoutSmart dickinsonLayoutOptions

dickinsonText :: Doc a -> T.Text
dickinsonText = renderStrict . smartDickinson

dickinsonLazyText :: Doc a -> TL.Text
dickinsonLazyText = renderLazy . smartDickinson

prettyText :: Pretty a => a -> T.Text
prettyText = dickinsonText . pretty

prettyLazyText :: Pretty a => a -> TL.Text
prettyLazyText = dickinsonLazyText . pretty
