import Foundation

/// Frequent English words the smart dictionary NEVER rewrites and never learns as a misheard
/// form ("their" / "there" must never snap). Keys are `Phonetics.key` form (lowercase, no
/// apostrophes: "they're" → "theyre"). Compiled into the app; nothing is read from disk.
public enum CommonWords {
    public static func contains(_ word: String) -> Bool { set.contains(Phonetics.key(word)) }

    /// True when every word of `phrase` is common.
    public static func allCommon(_ phrase: String) -> Bool {
        let words = phrase.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return !words.isEmpty && words.allSatisfy(contains)
    }

    public static let set: Set<String> = Set(list.split(separator: " ").map(String.init))

    // ~900 of the most frequent English words, plus contractions without apostrophes.
    private static let list = """
    a about above across act action actually add added after again against age ago agree ah ahead air all allow \
    almost alone along already also although always am among amount an and animal another answer any anyone \
    anything anyway appear apple apply are area arent arm around arrive art as ask at attention away baby back bad \
    bag ball bank bar base basic be bear beat beautiful became because become bed been before began begin behind \
    being believe below best better between big bill bird bit black blood blue board boat body book born both \
    bottom box boy break bring brother brought brown build building built business busy but buy by call called \
    came can cannot cant car card care carry case cat catch cause cell center central certain chair chance change \
    check child children choose church city class clean clear close cold college color come comes coming common \
    company complete computer consider contain continue control cook cool copy corner cost could couldnt country \
    couple course cover create cross cry cup current cut dad dark data date daughter day days dead deal dear death \
    decide deep design detail did didnt die difference different dinner direction do doctor does doesnt dog doing \
    done dont door double down draw dream dress drink drive drop dry during each early earth east easy eat edge \
    effect eight either else email end energy enough enter even evening event ever every everyone everything \
    exactly example except expect experience explain eye eyes face fact fall family far farm fast father fear feel \
    feet felt few field fight figure file fill final finally find fine finger finish fire first fish fit five fix \
    floor fly follow food foot for force form forward found four free friend from front full fun further future \
    game garden gave general get gets getting girl give given glass go goes going gone good got great green ground \
    group grow guess guy had hadnt hair half hand happen happy hard has hasnt hat have havent having he head hear \
    heard heart heat held hello help her here hers herself hey hi high him himself his history hit hold hole home \
    hope horse hot hour hours house how however huge human hundred i id idea if ill im important in include \
    including increase indeed information inside instead interest into is isnt issue it item its itself ive job \
    join just keep kept key kid kids kind king knew know known lady land language large last late later laugh law \
    lay lead learn least leave left leg less let lets letter level lie life light like likely line list listen \
    little live lived long look looking lose lost lot love low machine made main major make makes making man many \
    map mark market matter may maybe me mean meaning means meet meeting member men message met middle might mile \
    mind mine minute minutes miss moment money month months moon more morning most mother move movie much music \
    must my myself name names near nearly need needs never new news next nice night nine no none nor north not \
    note nothing notice now number object of off offer office often oh ok okay old on once one only open or order \
    other others our ours out outside over own page paid paper parent part party pass past pay people per perhaps \
    person phone pick picture piece place plan plant play please plus point police poor position possible post \
    power present pretty price probably problem process product program project pull push put question quick \
    quickly quite rain ran rather reach read ready real really reason receive record red remember report rest \
    result return right river road rock role room round rule run said same sat saw say saying says school sea \
    season second see seem seen sell send sense sent serve service set seven several shall shape share she shes \
    ship short should shouldnt show side sign simple since sing single sister sit six size sleep slow small smile \
    so social some someone something sometimes son song soon sorry sort sound south space speak special spend \
    spring stand star start state stay step still stop store story street strong student study stuff such sun \
    support sure system table take taken talk tax teacher team tell ten term test than thank thanks that thats \
    the their theirs them themselves then there theres these they theyd theyll theyre theyve thing things think \
    third this those though thought thousand three through throw time times to today together told tomorrow too \
    took top total touch toward town tree tried trip true try turn two type under understand unit until up upon \
    us use used using usual usually value very view visit voice wait walk wall want wanted war warm was wasnt \
    watch water way ways we wed week weeks weight well went were werent west what whats when where whether which \
    while white who whole whom whos whose why wide wife will win wind window wish with within without woman women \
    won wont wood word words work worked working world would wouldnt write written wrong wrote yeah year years yes \
    yet you youd youll young your youre yours yourself youve \
    by user id new man get set put via day today yesterday next last know there here hear here near dear deer \
    to too two for four fore by buy bye our hour are no know so sew sow right write rite see sea be bee its its \
    which witch weather whether wear where were whose whos lose loose than then accept except affect effect \
    break brake piece peace plain plane principal principle quite quiet sight site cite stationary stationery \
    tail scale mail male meet meat week weak won one sun son tale tail wait weight way weigh
    """
}
