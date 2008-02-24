;;; -*- show-trailing-whitespace: t; indent-tabs: nil -*-

;;; Copyright (c) 2007 Ivan Shvedunov. All rights reserved.
;;; Copyright (c) 2007 David Lichteblau. All rights reserved.

;;; Redistribution and use in source and binary forms, with or without
;;; modification, are permitted provided that the following conditions
;;; are met:
;;;
;;;   * Redistributions of source code must retain the above copyright
;;;     notice, this list of conditions and the following disclaimer.
;;;
;;;   * Redistributions in binary form must reproduce the above
;;;     copyright notice, this list of conditions and the following
;;;     disclaimer in the documentation and/or other materials
;;;     provided with the distribution.
;;;
;;; THIS SOFTWARE IS PROVIDED BY THE AUTHOR 'AS IS' AND ANY EXPRESSED
;;; OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
;;; WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
;;; ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
;;; DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
;;; DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE
;;; GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
;;; INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
;;; WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
;;; NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
;;; SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

(in-package :xpath)

;; types

;; * node-set (an unordered collection of nodes without duplicates) --> node-set
;; * boolean (true or false) --> nil / t ("list" is used in defgeneric)
;; * number (a floating-point number) --> xnum
;; * string (a sequence of UCS characters) --> string

(defun get-node-text (node)
  (xpath-protocol:string-value node))

(defclass node-set ()
  ((pipe :accessor pipe-of :initform empty-pipe :initarg :pipe)
   (ordering :accessor ordering-of :initform :unordered :initarg :ordering))
  (:documentation "Represents an XPath node set"))

(defmethod print-object ((object node-set) stream)
  (print-unreadable-object (object stream :type t :identity t)
    (if (pipe-of object)
	(format stream "~A, ~_..." (pipe-head (pipe-of object)))
	(write-string "empty" stream))))

(defun node-set-p (object)
  "@arg[object]{a value of any type}
   @return{a generalized boolean}
   Returns true if @code{object} is a @class{node-set}"
  (typep object 'node-set))

(defun node-set-empty-p (node-set)
  "@arg[node-set]{a node-set}
   @return{a generalized boolean}
   Returns true if @code{node-set} is empty"
  (pipe-empty-p (pipe-of node-set)))

(defun make-node-set (pipe &optional (ordering :unordered))
  (let ((visited (make-hash-table)))
    (make-instance 'node-set
		   :pipe (filter-pipe
			  #'(lambda (item)
			      (unless (gethash item visited)
				(setf (gethash item visited) t)))
			  pipe)
		   :ordering ordering)))

(defun sorted-pipe-of (node-set)
  (sort-pipe (pipe-of node-set) (ordering-of node-set)))

(defun sort-pipe (pipe &optional (ordering :unordered))
  (ecase ordering
    (:document-order
     pipe)
    (:reverse-document-order
     (reverse (force pipe)))
    (:unordered
     (sort (copy-list (force pipe)) #'node<))))

(defun textually-first-node (node-set)
  (let ((pipe (pipe-of node-set)))
    (ecase (ordering-of node-set)
      (:document-order
       (car pipe))
      (:reverse-document-order
       (let (result)
	 (enumerate pipe :key (lambda (elt) (setf result elt)))
	 result))
      (:unordered
       (let ((result (car pipe)))
	 (enumerate (pipe-tail pipe)
		    :key (lambda (elt)
			   (when (node< elt result)
			     (setf result elt))))
	 result)))))

;; equality

(defun node< (a b)
  "Compare nodes according to document order."
  (let* ((pp (force (funcall (axis-function :ancestor-or-self) a)))
	 (qq (force (funcall (axis-function :ancestor-or-self) b)))
	 (n (min (length pp) (length qq)))
	 (pp (last pp n))
	 (qq (last qq n)))
    (cond
      ((eq b (car pp))
       ;; same node, or b is an ancestor of a
       nil)
      ((eq a (car qq))
       ;; a is an ancestor of b
       t)
      (t
       ;; now pp and qq are different paths, leading to a common ancestor
       ;; somewhere:
       (loop
	  for (p nextp) on pp
	  for (q nextq) on qq
	  if (eq nextp nextq)
	  do (return
	       (let ((pa? (xpath-protocol:node-type-p p :attribute))
		     (qa? (xpath-protocol:node-type-p q :attribute))
		     (pn? (xpath-protocol:node-type-p p :namespace))
		     (qn? (xpath-protocol:node-type-p q :namespace)))
		 (cond
		   ;; special case for namespace and attribute of the same node
		   ;; namespaces come first:
		   ((and pn? qa?)
		    t)
		   ((and pa? qn?)
		    nil)
		   ;; I don't think that there's really an order defined
		   ;; for attributes, but axes_axes58 makes it sound like
		   ;; there is, so let's compare them according to the axis
		   ((and pa? qa?)
		    (enumerate (funcall (axis-function :attribute) nextp)
			       :key (lambda (x)
				      (when (eq x p)
					(return t))
				      (when (eq x q)
					(return nil)))
			       :result :error))
		   ;; namespaces and attributes both come before children:
		   ((or pa? pn?)
		    t)
		   ((or qa? qn?)
		    nil)
		   ;; in the normal case, walk the children:
		   (t
		    (enumerate
		     (funcall (axis-function :following-sibling) p)
		     :key (lambda (after-p)
			    (when (eq after-p q)
			      (return t)))
		     :result nil)))))
	  finally
	  ;; oops: someone tried to compare nodes from different
	  ;; documents.  Can happen with XSLT, can't do anything about it.
	  (return 0))))))

(defun sort-nodes (pipe)
  (sort (copy-list (force pipe)) #'node<))

(defun compare-node-sets (op a b) ;; FIXME: may be inefficient in some cases
  (if (eq op 'equal)
      (let ((table (make-hash-table :test #'equal)))
        (block nil
          (enumerate (pipe-of a) :key #'(lambda (item) (setf (gethash (get-node-text item) table) t)))
          (enumerate (pipe-of b) :key #'(lambda (item) (when (gethash (get-node-text item) table) (return t))))
          nil))
      (block nil
        (enumerate (pipe-of a) ;; FIXME: use min/max finding or something for <, >, <=, >=
                   :key #'(lambda (x)
                            (let ((x (number-value (get-node-text x))))
                              (enumerate (pipe-of b)
                                         :key #'(lambda (y)
                                                  (when (funcall op x (number-value (get-node-text y)))
                                                    (return t)))))))
        nil)))

(defun compare-with-node-set (op node-set value)
  (block nil
    (enumerate (pipe-of node-set)
               :key #'(lambda (node)
                        (when (compare/no-node-sets op (get-node-text node) value)
                          (return t))))
    nil))

(defun compare/no-node-sets (op a b)
  (cond ((or (not (eq op 'equal))
             (xnum-p a)
             (xnum-p b))
         (compare-numbers op (number-value a) (number-value b))) ;; FIXME: NaN
        ((or (typep a 'boolean) (typep b 'boolean))
         (equal (boolean-value a) (boolean-value b)))
        (t
         (string= (string-value a) (string-value b)))))

(defun compare-values (op a b)
  (cond ((and (node-set-p a) (node-set-p b))
         (compare-node-sets op a b))
        ((node-set-p a)
         (compare-with-node-set op a b))
        ((node-set-p b)
         (compare-with-node-set op b a))
        (t (compare/no-node-sets op a b))))

(defun boolean-value (value)
  "@arg[value]{value of an XPath-supported type or an XML node}
   @return{an XPath boolean}
   @short{Returns the value of XPath boolean() function.}

   For XML nodes returns the value of XPath boolean() function applied
   to the result of calling @see{string-value} for the specified @code{value}."
  (if (xpath-protocol:node-p value)
      (boolean-value (xpath-protocol:string-value value))
      (typecase value
        (string (not (equal value "")))
        (xnum (not (or (nan-p value)
                       (x-zerop value))))
        (node-set (not (pipe-empty-p (pipe-of value))))
        (t (if value t nil)))))

(defun number-value (value)
  "@arg[value]{value of an XPath-supported type or an XML node}
   @return{an XPath number}
   @short{Returns the value of XPath number() function.}

   For XML nodes returns the value of XPath number() function applied
   to the result of calling @see{string-value} for the specified @code{value}."
  (if (xpath-protocol:node-p value)
      (number-value (xpath-protocol:string-value value))
      (typecase value
        (string (parse-xnum value)) ;; FIXME!!!! it should be double-float; how to handle junk? NaN?
        (xnum value)
        (node-set (number-value (string-value value)))
        (t (if value 1 0)))))

(defun string-value (value)
  "@arg[value]{value of an XPath-supported type or an XML node}
   @return{an XPath string}
   @short{Returns the value of XPath number() function.}

   For XML nodes returns the value of @see{xpath-protocol:string-value} applied
   to the specified @code{value}."
  (if (xpath-protocol:node-p value)
      (string-value (xpath-protocol:string-value value))
      (typecase value
        (string value)
        (xnum (xnum->string value)) ;; fixme; probably also should use format string
        (node-set
         (if (pipe-empty-p (pipe-of value))
             ""
             (get-node-text (textually-first-node value))))
        (t (if value "true" "false")))))

(defun node-set-value (value)
  "@arg[value]{value of an XPath-supported type or an XML node}
   @return{a node set}
   @short{Returns the value of XPath node-set() function.}

   For XML nodes returns a node set consisting of the single node specified
   by @code{value}."
  (cond ((node-set-p value)
         value)
        ((xpath-protocol:node-p value)
         (make-node-set (list value) :document-order))
        (t
         (error "cannot convert ~s to a NODE-SET" value))))

;; context

(defclass context ()
  ((node :initarg :node)
   (size :initarg :size)
   (position :initarg :position)
   (starting-node :initarg :starting-node))
  (:documentation "Represents XPath context"))

(defun make-context (node &optional (size 1) (position 1) (starting-node node))
  "@arg[node]{an XML node}
   @arg[size]{context size, a non-negative integer or a function without arguments returning non-negative integer}
   @arg[position]{context position, a positive integer}
   Makes a @class{context} object."
  (make-instance 'context :node node :size size :position position
		 :starting-node starting-node))

(defun context-node (context)
  "@arg[context]{an XPath context}
   @return{an XML node}
   Returns the context node of the XPath @code{context}."
  (slot-value context 'node))

(defun (setf context-node) (node context)
  "@arg[node]{an XML node}
   @arg[context]{an XPath context}
   @return{the @code{node}}
   Sets the context node of @code{context} and returns that node."
  (setf (slot-value context 'node) node))

(defun context-size (context)
  "@arg[context]{an XPath context}
   @return{a non-negative number}
   @short{Returns the size of @code{context}}
   If the context size was specified as a function,
   the result of calling that function is returned."
  (with-slots (size) context
     (if (functionp size)
        (setf size (funcall size)) size)))

(defun (setf context-size) (size context)
  "@arg[size]{context size, a non-negative integer or a function without arguments returning non-negative integer}
   @arg[context]{an XPath context}
   @return{the value of @code{size}}
   Sets the size of the XPath @code{context} and returns it."
  (setf (slot-value context 'size) size))

(defun context-position (context)
  "@arg[context]{an XPath context}
   @return{a positive integer}
   Returns the current position of the XPath @code{context}."
  (slot-value context 'position))

(defun (setf context-position) (position context)
  "@arg[position]{context position, a positive integer}
   @arg[context]{an XPath context}
   @return{the value of @code{position}}
   Sets the position of the XPath @code{context} and returns it."
  (setf (slot-value context 'position) position))

(defun context-starting-node (context)
  "@arg[context]{an XPath context}
   @return{an XML node}
   Returns the node for which the whole XPath expression is evaluated."
  (slot-value context 'starting-node))

(defun (setf context-starting-node) (node context)
  "@arg[context]{an XPath context}
   @return{the value of @code{node}}
   Sets the node which is considered \"starting\" one, i.e. for which the whole
   XPath extension is evaluated."
  (setf (slot-value context 'starting-node) node))
