'' # Describing a set of numbers
''
'' Twelve students wrote down how many minutes their trip to class took.
'' Three numbers say most of what there is to say about a list like this:
'' where its **middle** is, in two senses, and how **spread out** it is.
'' You will write each one yourself, and then check it against the
'' function gBASIC already has.
'
' 08 — A lesson: exercises, checks, and a student edition.
'
' This is the INSTRUCTOR'S file. The lines beginning ' @ and '' @ mark the
' exercises, their solutions, the starter code a student gets instead, and
' the checks that say whether an exercise is done. They are all comments,
' so the file runs as ordinary gBASIC.
'
' Try this:
'   1. Lesson > Check Lesson. A note appears under each exercise: the
'      solution passes its checks, and the student edition still fails them.
'   2. Lesson > Export Student Edition. 08_lesson.student.bas opens: the
'      solutions are replaced by starter code, and the private checks are
'      not in it at all.
'   3. In the student edition, Lesson > Check Lesson. Nothing is done yet.
'      Write `average` and check again: that exercise says Done.

commute = [12, 25, 8, 30, 15, 45, 10, 22, 18, 9, 35, 14]
print "minutes: " + string(commute)

'' @exercise average "The mean"
''
'' The **mean** is the total divided by how many there are. Write
'' `average(xs)` without using `mean`: add the numbers up with a loop.
' @starter
' function average(xs)
'     return 0
' end function
' @end
' @solution
function average(xs)
    total = 0
    for each x in xs
        total = total + x
    end for
    return total / count(xs)
end function
' @end
' @check
print average([2, 4, 4, 5]) = 3.75
print average([7]) = 7
' @end
' @check private
print average(commute) = mean(commute)
' @end
'' @hint `total = total + x` inside a `for each` loop adds them up.
'' @tutor If the answer is off by a lot, ask whether they divided by the count or by the last number.

'' @exercise middle "The median"
''
'' The **median** is the middle value once the list is sorted. With an even
'' count there are two middle values, and the median is halfway between them.
'' Remember that arrays count from 0.
' @starter
' function middle(xs)
'     return 0
' end function
' @end
' @solution
function middle(xs)
    s = sort(xs)
    n = count(s)
    if mod(n, 2) = 1 then
        return s[floor(n / 2)]
    end if
    return (s[n / 2 - 1] + s[n / 2]) / 2
end function
' @end
' @check
print middle([3, 1, 2]) = 2
print middle([4, 1, 2, 3]) = 2.5
' @end
' @check private
print middle(commute) = median(commute)
' @end
'' @hint `mod(n, 2) = 1` is true when the count is odd.
'' @tutor An off-by-one here is almost always the 0-based index; ask which position the middle of three is.

'' @exercise spread "The standard deviation"
''
'' The **standard deviation** says how far values typically sit from the
'' mean. For a sample: add up the squared distance of each value from the
'' mean, divide by one less than the count, and take the square root.
' @starter
' function spread(xs)
'     return 0
' end function
' @end
' @solution
function spread(xs)
    m = average(xs)
    total = 0
    for each x in xs
        total = total + (x - m) * (x - m)
    end for
    return sqrt(total / (count(xs) - 1))
end function
' @end
' @check
print round(spread([2, 4, 4, 4, 5, 5, 7, 9]), 4) = 2.1381
' @end
' @check private
print round(spread(commute), 6) = round(stdev(commute), 6)
' @end
'' @hint gBASIC has no `^` operator: write `(x - m) * (x - m)`.
'' @tutor Dividing by the count instead of count - 1 gives the population figure; ask which one the data is.

'' ## What the three numbers say

summary = []
summary = append(summary, { measure: "mean", minutes: round(average(commute), 1) })
summary = append(summary, { measure: "median", minutes: middle(commute) })
summary = append(summary, { measure: "standard deviation", minutes: round(spread(commute), 1) })
